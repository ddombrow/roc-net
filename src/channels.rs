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
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use crate::resource::ResourceHeap;
use crate::roc_host;
use crate::roc_platform_abi::{
    decref_erased_callable, AnonStructDfa5943259877aa7 as RocChannelEnds, ClosedOrFullOrSent,
    ClosedOrTimedOut, HostChannelNewResult, HostChannelNewResultPayload, HostChannelNewResultTag,
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
}

struct Channel {
    state: Mutex<State>,
    not_empty: Condvar,
    not_full: Condvar,
}

impl Channel {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn close_sending(&self) {
        self.lock().sending_closed = true;
        // Wake receivers waiting for values and senders waiting for room.
        self.not_empty.notify_all();
        self.not_full.notify_all();
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
                    state.queue.drain(..).collect()
                };
                channel.not_full.notify_all();
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
        }),
        not_empty: Condvar::new(),
        not_full: Condvar::new(),
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
pub extern "C" fn roc_channel_send(end: *mut u64, value: RocErasedCallable, wait: bool) -> ClosedOrFullOrSent {
    let value = Thunk(value);
    with_end(end, |end| {
        let Some(End::Sender(channel)) = end else {
            return ClosedOrFullOrSent::Closed;
        };
        let mut state = channel.lock();
        loop {
            if state.sending_closed || state.receiver_gone {
                drop(state);
                drop(value);
                return ClosedOrFullOrSent::Closed;
            }
            if state.queue.len() < state.capacity {
                state.queue.push_back(value);
                drop(state);
                channel.not_empty.notify_one();
                return ClosedOrFullOrSent::Sent;
            }
            if !wait {
                drop(state);
                drop(value);
                return ClosedOrFullOrSent::Full;
            }
            state = channel.not_full.wait(state).unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    })
}

fn receive_err(err: ClosedOrTimedOut) -> HostChannelReceiveResult {
    HostChannelReceiveResult {
        payload: HostChannelReceiveResultPayload { err: std::mem::ManuallyDrop::new(err) },
        tag: HostChannelReceiveResultTag::Err,
    }
}

/// Hosted function: Host.channel_receive!
#[no_mangle]
pub extern "C" fn roc_channel_receive(end: *mut u64, timeout_ns: u64) -> HostChannelReceiveResult {
    let deadline = (timeout_ns != u64::MAX).then(|| Instant::now() + Duration::from_nanos(timeout_ns));
    with_end(end, |end| {
        let Some(End::Receiver(channel)) = end else {
            return receive_err(ClosedOrTimedOut::Closed);
        };
        let mut state = channel.lock();
        loop {
            if let Some(value) = state.queue.pop_front() {
                drop(state);
                channel.not_full.notify_one();
                return HostChannelReceiveResult {
                    payload: HostChannelReceiveResultPayload {
                        ok: std::mem::ManuallyDrop::new(value.into_raw()),
                    },
                    tag: HostChannelReceiveResultTag::Ok,
                };
            }
            if state.sending_closed {
                return receive_err(ClosedOrTimedOut::Closed);
            }
            state = match deadline {
                None => channel.not_empty.wait(state).unwrap_or_else(|poisoned| poisoned.into_inner()),
                Some(deadline) => {
                    let now = Instant::now();
                    if now >= deadline {
                        return receive_err(ClosedOrTimedOut::TimedOut);
                    }
                    channel
                        .not_empty
                        .wait_timeout(state, deadline - now)
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .0
                }
            };
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
