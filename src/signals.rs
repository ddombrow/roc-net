//! Signals (`Signal`, and `Select.on_signal`): SIGINT, SIGTERM, SIGHUP,
//! SIGUSR1 and SIGUSR2, once a program asks to catch them.
//!
//! A signal handler may only do async-signal-safe things, so it just sets
//! the signal's bit in [`PENDING`] and writes a byte to a pipe. One helper
//! thread reads the pipe, moves the pending signals onto a queue, and wakes
//! the tasks waiting for one. A signal that arrives again while it's still
//! queued counts once, as the operating system counts it.

use std::collections::VecDeque;
use std::io;
use std::sync::atomic::{AtomicI32, AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use crate::sched::{self, TaskWaker, Waiters, Woke};

/// The signals that can be caught, by code: the order of `Signal.Kind`'s
/// tags in platform/Signal.roc.
const SIGNALS: [libc::c_int; 5] = [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGUSR1, libc::SIGUSR2];

/// Signals received and not yet queued, one bit per code.
static PENDING: AtomicU32 = AtomicU32::new(0);
/// The pipe's write end, for the handler; -1 until the first `catch`.
static PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);

struct State {
    queue: VecDeque<u8>,
    caught: u32,
    started: bool,
    watchers: Waiters,
}

static STATE: Mutex<State> = Mutex::new(State { queue: VecDeque::new(), caught: 0, started: false, watchers: Waiters::new() });

fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

extern "C" fn handler(signal: libc::c_int) {
    // Only atomics and write(2) here; errno is put back for the code this
    // interrupted.
    let errno = io::Error::last_os_error().raw_os_error();
    if let Some(code) = SIGNALS.iter().position(|&s| s == signal) {
        PENDING.fetch_or(1 << code, Ordering::SeqCst);
        let fd = PIPE_WRITE.load(Ordering::SeqCst);
        if fd >= 0 {
            // A full pipe already holds a wake-up for the reader.
            unsafe { libc::write(fd, [code as u8].as_ptr() as *const libc::c_void, 1) };
        }
    }
    if let Some(errno) = errno {
        unsafe { *errno_location() = errno };
    }
}

#[cfg(target_os = "linux")]
unsafe fn errno_location() -> *mut libc::c_int {
    libc::__errno_location()
}

#[cfg(target_os = "macos")]
unsafe fn errno_location() -> *mut libc::c_int {
    libc::__error()
}

/// Start catching the signals with these codes (see [`SIGNALS`]).
pub fn catch(codes: &[u8]) -> io::Result<()> {
    let mut state = state();
    if !state.started {
        let mut fds = [0 as libc::c_int; 2];
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        }
        // The handler must never block on a full pipe.
        unsafe { libc::fcntl(fds[1], libc::F_SETFL, libc::fcntl(fds[1], libc::F_GETFL) | libc::O_NONBLOCK) };
        let read_end = fds[0];
        std::thread::Builder::new().name("roc-net-signals".into()).spawn(move || read_signals(read_end))?;
        PIPE_WRITE.store(fds[1], Ordering::SeqCst);
        state.started = true;
    }
    for &code in codes {
        let Some(&signal) = SIGNALS.get(code as usize) else { continue };
        if state.caught & (1 << code) != 0 {
            continue;
        }
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        action.sa_sigaction = handler as extern "C" fn(libc::c_int) as usize;
        action.sa_flags = libc::SA_RESTART;
        unsafe { libc::sigemptyset(&mut action.sa_mask) };
        if unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        state.caught |= 1 << code;
    }
    Ok(())
}

fn read_signals(fd: libc::c_int) {
    let mut buf = [0u8; 64];
    loop {
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return;
        }
        let pending = PENDING.swap(0, Ordering::SeqCst);
        if pending == 0 {
            continue;
        }
        let mut state = state();
        for code in 0..SIGNALS.len() as u8 {
            if pending & (1 << code) != 0 && !state.queue.contains(&code) {
                state.queue.push_back(code);
            }
        }
        state.watchers.wake_all();
    }
}

/// The next signal received, if one has been.
pub fn try_next() -> Option<u8> {
    state().queue.pop_front()
}

pub enum Watch {
    Ready,
    Waiting(u64),
}

/// For a `Select` that found no signal: register `waker`, unless one has
/// arrived since.
pub fn watch(waker: &TaskWaker) -> Watch {
    let mut state = state();
    if !state.queue.is_empty() {
        return Watch::Ready;
    }
    Watch::Waiting(state.watchers.add_waker(waker.clone()))
}

pub fn unwatch(id: u64) {
    state().watchers.remove(id);
}

/// Wait for the next signal; `None` if the task is cancelled first.
pub fn next() -> Option<u8> {
    loop {
        if let Some(code) = try_next() {
            return Some(code);
        }
        let Some(wait) = sched::begin_multi_wait() else {
            std::thread::sleep(Duration::from_millis(1));
            continue;
        };
        match watch(&wait.waker()) {
            Watch::Ready => wait.abandon(),
            Watch::Waiting(id) => {
                let woke = wait.wait(None);
                unwatch(id);
                if woke == Woke::Cancelled {
                    return None;
                }
            }
        }
    }
}

// --- Hosted functions ---

use std::mem::ManuallyDrop;

use crate::net::{FromNetErr, NetErr};
use crate::roc_host;
use crate::roc_platform_abi::{
    CancelledOrGot, CancelledOrGotPayload, CancelledOrGotTag, GotOrNotReady, GotOrNotReadyPayload, GotOrNotReadyTag,
    HostSignalCatchResult, HostSignalCatchResultPayload, HostSignalCatchResultTag, RocListWith,
};

/// Hosted function: Host.signal_catch!
#[no_mangle]
pub extern "C" fn roc_signal_catch(codes: RocListWith<u8, false>) -> HostSignalCatchResult {
    let result = catch(codes.as_slice());
    unsafe { codes.decref(roc_host()) };
    match result {
        Ok(()) => HostSignalCatchResult { payload: HostSignalCatchResultPayload { ok: [] }, tag: HostSignalCatchResultTag::Ok },
        Err(err) => HostSignalCatchResult {
            payload: HostSignalCatchResultPayload { err: ManuallyDrop::new(FromNetErr::from_net_err(NetErr::Io(err))) },
            tag: HostSignalCatchResultTag::Err,
        },
    }
}

/// Hosted function: Host.signal_try_next!
#[no_mangle]
pub extern "C" fn roc_signal_try_next() -> GotOrNotReady {
    match try_next() {
        Some(code) => GotOrNotReady { payload: GotOrNotReadyPayload { got: ManuallyDrop::new(code) }, tag: GotOrNotReadyTag::Got },
        None => GotOrNotReady { payload: GotOrNotReadyPayload { not_ready: [] }, tag: GotOrNotReadyTag::NotReady },
    }
}

/// Hosted function: Host.signal_next!
#[no_mangle]
pub extern "C" fn roc_signal_next() -> CancelledOrGot {
    match next() {
        Some(code) => CancelledOrGot { payload: CancelledOrGotPayload { got: ManuallyDrop::new(code) }, tag: CancelledOrGotTag::Got },
        None => CancelledOrGot { payload: CancelledOrGotPayload { cancelled: [] }, tag: CancelledOrGotTag::Cancelled },
    }
}
