//! `Host.select_wait!`: wait on several sockets, channel ends and tasks at once,
//! for `Select` (platform/Select.roc), which polls each source without
//! waiting (`socket_try_read!`, `try_receive!`, ...) and calls this only when
//! none was ready.

use std::time::{Duration, Instant};

use crate::roc_host;
use crate::roc_platform_abi::{
    decref_list_of_joinable_or_readable_or_receivable_or_sendable_or_writable as decref_sources,
    CancelledOrReadyOrSourceTimedOutOrTimedOut as Outcome,
    CancelledOrReadyOrSourceTimedOutOrTimedOutPayload as OutcomePayload,
    CancelledOrReadyOrSourceTimedOutOrTimedOutTag as OutcomeTag, JoinableOrReadableOrReceivableOrSendableOrWritable as Source,
    JoinableOrReadableOrReceivableOrSendableOrWritableTag as SourceTag, RocList,
};
use crate::sched::{self, Woke};
use crate::sockets::Socket;

/// Hosted function: Host.select_turn!
#[no_mangle]
pub extern "C" fn roc_select_turn() -> u64 {
    static TURN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    TURN.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

/// Hosted function: Host.select_wait!
#[no_mangle]
pub extern "C" fn roc_select_wait(sources: RocList<Source>, timeout_ns: u64) -> Outcome {
    // U64.highest means no limit; so does a timeout too long to represent.
    let deadline = (timeout_ns != u64::MAX).then(|| Instant::now().checked_add(Duration::from_nanos(timeout_ns))).flatten();
    // The list holds a reference to every source until it's released at the
    // end, so the sockets and channels stay alive while being waited on.
    let outcome = wait_any(sources.as_slice(), deadline);
    unsafe { decref_sources(sources, roc_host()) };
    outcome
}

fn outcome(tag: OutcomeTag) -> Outcome {
    Outcome { payload: OutcomePayload { ready: [] }, tag }
}

/// What a source registered, to undo once the wait is over.
enum Watching {
    Channel(*mut u64, u64),
    Tls(*mut u64, u64),
    Task(*mut u64, u64),
}

fn wait_any(sources: &[Source], deadline: Option<Instant>) -> Outcome {
    if deadline.is_some_and(|at| Instant::now() >= at) {
        return outcome(OutcomeTag::TimedOut);
    }
    let Some(mut wait) = sched::begin_multi_wait() else {
        // Not in a task (never the case for Roc code): poll again shortly.
        std::thread::sleep(Duration::from_millis(1));
        return outcome(OutcomeTag::Ready);
    };
    let waker = wait.waker();
    let mut watching = Vec::new();
    // Streams' own deadlines, by source index: a Select mustn't wait on a
    // silent peer longer than a blocking read of it would (its read timeout,
    // counted from now, or a TLS handshake deadline).
    let mut stream_deadlines = Vec::new();
    // A source that's ready (or can't be watched, so its poll will say why)
    // ends the wait before it starts.
    let mut ready = false;
    for (index, source) in sources.iter().enumerate() {
        if source.tag == SourceTag::Joinable {
            let handle = unsafe { *source.borrow_payload_joinable_unchecked() };
            match crate::tasks::watch(handle, &waker) {
                None => {
                    ready = true;
                    break;
                }
                Some(id) => {
                    watching.push(Watching::Task(handle, id));
                    continue;
                }
            }
        }
        // Each accessor is only valid for its own tag.
        let (handle, is_socket, writable) = unsafe {
            match source.tag {
                SourceTag::Readable => (*source.borrow_payload_readable_unchecked(), true, false),
                SourceTag::Writable => (*source.borrow_payload_writable_unchecked(), true, true),
                SourceTag::Receivable => (*source.borrow_payload_receivable_unchecked(), false, false),
                SourceTag::Sendable => (*source.borrow_payload_sendable_unchecked(), false, true),
                SourceTag::Joinable => unreachable!("handled above"),
            }
        };
        if is_socket {
            let Some(socket) = (unsafe { crate::sockets::get(handle) }) else {
                ready = true;
                break;
            };
            if !writable {
                if let Some(at) = socket.read_wait_deadline() {
                    stream_deadlines.push((index, at));
                }
            }
            // TLS can be ready without the socket showing it: another task
            // may release a lock after leaving plaintext behind, or a reply
            // may be waiting for the socket to take it.
            let mut also_writable = false;
            if let (Socket::Tls(tls), false) = (socket, writable) {
                match tls.watch(&waker) {
                    crate::tls::Watch::Ready => {
                        ready = true;
                        break;
                    }
                    crate::tls::Watch::Waiting { id, wants_write } => {
                        watching.push(Watching::Tls(handle, id));
                        also_writable = wants_write;
                    }
                }
            }
            let (fd, reg) = socket.io_parts();
            let added = wait.add_io(fd, reg, writable).is_ok() && (!also_writable || wait.add_io(fd, reg, true).is_ok());
            if !added {
                ready = true;
                break;
            }
        } else {
            match crate::channels::watch(handle, &waker) {
                crate::channels::Watch::Ready => {
                    ready = true;
                    break;
                }
                crate::channels::Watch::Waiting(id) => watching.push(Watching::Channel(handle, id)),
            }
        }
    }
    let first_stream_deadline = stream_deadlines.iter().min_by_key(|&&(_, at)| at).copied();
    let wait_until = match (deadline, first_stream_deadline) {
        (Some(a), Some((_, b))) => Some(a.min(b)),
        (a, b) => a.or(b.map(|(_, at)| at)),
    };
    let result = if ready {
        wait.abandon();
        outcome(OutcomeTag::Ready)
    } else {
        match wait.wait(wait_until) {
            Woke::Ready => outcome(OutcomeTag::Ready),
            Woke::Cancelled => outcome(OutcomeTag::Cancelled),
            Woke::TimedOut => match first_stream_deadline {
                // A stream's deadline came first: tell this Select which, so
                // it reports that arm's timeout (and no other Select's).
                Some((index, at)) if deadline.is_none_or(|limit| at < limit) => Outcome {
                    payload: OutcomePayload { source_timed_out: std::mem::ManuallyDrop::new(index as u64) },
                    tag: OutcomeTag::SourceTimedOut,
                },
                _ => outcome(OutcomeTag::TimedOut),
            },
        }
    };
    for watch in watching {
        match watch {
            Watching::Channel(handle, id) => crate::channels::unwatch(handle, id),
            Watching::Task(handle, id) => crate::tasks::unwatch(handle, id),
            Watching::Tls(handle, id) => {
                if let Some(Socket::Tls(tls)) = unsafe { crate::sockets::get(handle) } {
                    tls.unwatch(id);
                }
            }
        }
    }
    result
}
