//! Bounded channels between tasks.
//!
//! Roc values cross as erased thunks (`Box(() -> a)`): a boxed closure has a
//! fixed shape and carries its own drop callback, so the host can queue a
//! value of any type and release it correctly if it's never received.
//!
//! Each channel has one sender end and one receiver end, both Roc-owned
//! handles like sockets (see `resource.rs`). Any number of tasks may share an
//! end. When the sender end is released (or closed), receivers get what's
//! queued and then `Closed`; when the receiver end is released, senders get
//! `Closed` and queued values are dropped.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use crate::resource::ResourceHeap;
use crate::sched::{self, Waiters};
use crate::roc_host;
use crate::roc_platform_abi::{
    decref_erased_callable, AnonStructDfa5943259877aa7 as RocChannelEnds, CancelledOrClosedOrFullOrSent,
    CancelledOrClosedOrTimedOut, HostChannelNewResult, HostChannelNewResultPayload, HostChannelNewResultTag,
    HostChannelReceiveResult, HostChannelReceiveResultPayload, HostChannelReceiveResultTag,
    RocErasedCallable,
};

/// One Roc reference to a queued value's thunk. Dropping it releases that
/// reference (freeing the value if it was the last).
struct Thunk(RocErasedCallable);

// Roc refcounts are atomic and this is the only reference the host holds.
unsafe impl Send for Thunk {}

impl Thunk {
    /// Hand the reference to Roc.
    fn into_raw(self) -> RocErasedCallable {
        let raw = self.0;
        std::mem::forget(self);
        raw
    }
}

impl Drop for Thunk {
    fn drop(&mut self) {
        unsafe { decref_erased_callable(self.0, roc_host()) };
    }
}

struct State {
    queue: VecDeque<Thunk>,
    capacity: usize,
    /// No more values will be sent (the sender end is gone or closed).
    sending_closed: bool,
    /// Nobody will receive (the receiver end is gone).
    receiver_gone: bool,
    /// Tasks waiting for a value, and for room. One of each is woken per
    /// value or slot, so each must be a task that will act on it.
    receivers: Waiters,
    senders: Waiters,
    /// `Select`s watching for a value, or for room. All are woken on every
    /// change: a `Select` may take another arm, and a notification spent on
    /// it would otherwise be lost to the plain waiters above.
    receive_watchers: Waiters,
    send_watchers: Waiters,
}

impl State {
    fn value_added(&mut self) {
        self.receivers.wake_one();
        self.receive_watchers.wake_all();
    }

    fn room_made(&mut self) {
        self.senders.wake_one();
        self.send_watchers.wake_all();
    }

    fn wake_everyone(&mut self) {
        self.receivers.wake_all();
        self.senders.wake_all();
        self.receive_watchers.wake_all();
        self.send_watchers.wake_all();
    }
}

struct Channel {
    state: Mutex<State>,
}

impl Channel {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn close_sending(&self) {
        let mut state = self.lock();
        state.sending_closed = true;
        // Wake receivers waiting for values and senders waiting for room.
        state.wake_everyone();
    }
}

enum End {
    Sender(Arc<Channel>),
    Receiver(Arc<Channel>),
}

impl Drop for End {
    fn drop(&mut self) {
        match self {
            End::Sender(channel) => channel.close_sending(),
            End::Receiver(channel) => {
                let undelivered: Vec<Thunk> = {
                    let mut state = channel.lock();
                    state.receiver_gone = true;
                    state.wake_everyone();
                    state.queue.drain(..).collect()
                };
                // Dropped outside the lock: freeing a value can run Roc drop
                // code that releases other handles, even this channel's.
                drop(undelivered);
            }
        }
    }
}

static HEAP: OnceLock<ResourceHeap<End>> = OnceLock::new();

fn heap() -> &'static ResourceHeap<End> {
    HEAP.get_or_init(|| ResourceHeap::new(crate::limits::max_channels() * 2))
}

/// Called by `roc_dealloc`. Returns true if `ptr` was a channel end, which is
/// now released and must not be freed as ordinary memory.
pub fn release(ptr: *mut std::ffi::c_void) -> bool {
    // Don't create the heap just to learn a pointer isn't in it.
    HEAP.get().is_some_and(|heap| heap.release(ptr))
}

/// Run `f` on the channel behind a handle, then release the handle.
fn with_end<T>(handle: *mut u64, f: impl FnOnce(Option<&End>) -> T) -> T {
    let result = f(unsafe { heap().get(handle) }.ok());
    unsafe {
        crate::roc_platform_abi::decref_box_with(
            handle as crate::roc_platform_abi::RocBox,
            core::mem::align_of::<u64>(),
            false,
            None,
            roc_host(),
        )
    };
    result
}

/// Hosted function: Host.channel_new!
#[no_mangle]
pub extern "C" fn roc_channel_new(capacity: u64) -> HostChannelNewResult {
    let reserved = heap().try_reserve().and_then(|a| heap().try_reserve().map(|b| (a, b)));
    let Ok((sender_slot, receiver_slot)) = reserved else {
        return HostChannelNewResult {
            payload: HostChannelNewResultPayload { err: [] },
            tag: HostChannelNewResultTag::Err,
        };
    };
    let channel = Arc::new(Channel {
        state: Mutex::new(State {
            queue: VecDeque::new(),
            capacity: capacity.max(1) as usize,
            sending_closed: false,
            receiver_gone: false,
            receivers: Waiters::new(),
            senders: Waiters::new(),
            receive_watchers: Waiters::new(),
            send_watchers: Waiters::new(),
        }),
    });
    let ends = RocChannelEnds {
        sender: sender_slot.insert(End::Sender(channel.clone())),
        receiver: receiver_slot.insert(End::Receiver(channel)),
    };
    HostChannelNewResult {
        payload: HostChannelNewResultPayload { ok: std::mem::ManuallyDrop::new(ends) },
        tag: HostChannelNewResultTag::Ok,
    }
}

/// Hosted function: Host.channel_send!
#[no_mangle]
pub extern "C" fn roc_channel_send(end: *mut u64, value: RocErasedCallable, wait: bool) -> CancelledOrClosedOrFullOrSent {
    let value = Thunk(value);
    with_end(end, |end| {
        let Some(End::Sender(channel)) = end else {
            return CancelledOrClosedOrFullOrSent::Closed;
        };
        let mut state = channel.lock();
        loop {
            if state.sending_closed || state.receiver_gone {
                drop(state);
                drop(value);
                return CancelledOrClosedOrFullOrSent::Closed;
            }
            if state.queue.len() < state.capacity {
                state.queue.push_back(value);
                state.value_added();
                return CancelledOrClosedOrFullOrSent::Sent;
            }
            if !wait {
                drop(state);
                drop(value);
                return CancelledOrClosedOrFullOrSent::Full;
            }
            let id = state.senders.add();
            drop(state);
            let end = sched::park(None);
            state = channel.lock();
            state.senders.remove(id);
            if end == sched::Woke::Cancelled {
                drop(state);
                drop(value);
                return CancelledOrClosedOrFullOrSent::Cancelled;
            }
        }
    })
}

fn receive_err(err: CancelledOrClosedOrTimedOut) -> HostChannelReceiveResult {
    HostChannelReceiveResult {
        payload: HostChannelReceiveResultPayload { err: std::mem::ManuallyDrop::new(err) },
        tag: HostChannelReceiveResultTag::Err,
    }
}

/// Hosted function: Host.channel_receive!
#[no_mangle]
pub extern "C" fn roc_channel_receive(end: *mut u64, timeout_ns: u64) -> HostChannelReceiveResult {
    // U64.highest means wait as long as it takes; so does any timeout too long
    // to represent as a moment (see `deadline_after` in net.rs).
    let deadline = (timeout_ns != u64::MAX)
        .then(|| Instant::now().checked_add(Duration::from_nanos(timeout_ns)))
        .flatten();
    with_end(end, |end| {
        let Some(End::Receiver(channel)) = end else {
            return receive_err(CancelledOrClosedOrTimedOut::Closed);
        };
        let mut state = channel.lock();
        loop {
            if let Some(value) = state.queue.pop_front() {
                state.room_made();
                drop(state);
                return HostChannelReceiveResult {
                    payload: HostChannelReceiveResultPayload {
                        ok: std::mem::ManuallyDrop::new(value.into_raw()),
                    },
                    tag: HostChannelReceiveResultTag::Ok,
                };
            }
            if state.sending_closed {
                return receive_err(CancelledOrClosedOrTimedOut::Closed);
            }
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return receive_err(CancelledOrClosedOrTimedOut::TimedOut);
            }
            let id = state.receivers.add();
            drop(state);
            let end = sched::park(deadline);
            state = channel.lock();
            state.receivers.remove(id);
            if end == sched::Woke::Cancelled {
                return receive_err(CancelledOrClosedOrTimedOut::Cancelled);
            }
        }
    })
}

/// Hosted function: Host.channel_close!
#[no_mangle]
pub extern "C" fn roc_channel_close(end: *mut u64) {
    with_end(end, |end| {
        if let Some(End::Sender(channel)) = end {
            channel.close_sending();
        }
    });
}

/// Whether a channel end watched by a `Select` is ready now.
pub enum Watch {
    /// Ready: a value or the end of the channel (for a receiver), room or a
    /// gone receiver (for a sender). Nothing was registered.
    Ready,
    /// Not yet: `waker` is registered under this id; remove it with
    /// [`unwatch`] once the wait is over.
    Waiting(u64),
}

/// For `Select`: check a channel end, and if it isn't ready, register
/// `waker` to be woken when it may be. The handle is borrowed (the caller
/// keeps its reference until after [`unwatch`]).
pub fn watch(handle: *mut u64, waker: &sched::TaskWaker) -> Watch {
    let Ok(end) = (unsafe { heap().get(handle) }) else { return Watch::Ready };
    match end {
        End::Receiver(channel) => {
            let mut state = channel.lock();
            if !state.queue.is_empty() || state.sending_closed {
                return Watch::Ready;
            }
            Watch::Waiting(state.receive_watchers.add_waker(waker.clone()))
        }
        End::Sender(channel) => {
            let mut state = channel.lock();
            if state.queue.len() < state.capacity || state.sending_closed || state.receiver_gone {
                return Watch::Ready;
            }
            Watch::Waiting(state.send_watchers.add_waker(waker.clone()))
        }
    }
}

/// Undo a [`watch`] that returned `Waiting(id)`.
pub fn unwatch(handle: *mut u64, id: u64) {
    let Ok(end) = (unsafe { heap().get(handle) }) else { return };
    match end {
        End::Receiver(channel) => channel.lock().receive_watchers.remove(id),
        End::Sender(channel) => channel.lock().send_watchers.remove(id),
    }
}
