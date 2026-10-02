//! Standard input, a line at a time, for `Stdin` and `Select`.
//!
//! Reading a terminal or pipe blocks and can't be interrupted, so one
//! reader thread does it, a line at a time and only when one is wanted, and
//! queues each line it reads. Every reader takes lines from that queue:
//! `Stdin.line!`, `Stdin.read_line!`, and `Select`'s stdin arm. So a line
//! read for a task that's cancelled (or a `Select` another arm won) isn't
//! lost: the next reader gets it, in order.

use std::collections::VecDeque;
use std::io::{self, BufRead};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::Duration;

use crate::sched::{self, TaskWaker, Waiters, Woke};

/// The longest line kept, without its line ending. Past it, the rest of the
/// line is read and dropped, and the line reads as [`Line::TooLong`]: a
/// line from an untrusted source can't use up the program's memory.
pub const MAX_LINE: usize = 1024 * 1024;

/// What a read of stdin gets.
pub enum Line {
    /// A line, without its line ending.
    Text(String),
    /// A line longer than [`MAX_LINE`], skipped.
    TooLong,
    /// The end of input.
    End,
    Failed(io::Error),
}

struct State {
    /// Read, and not yet taken.
    queue: VecDeque<Line>,
    /// The reader thread should read another line.
    wanted: bool,
    started: bool,
    /// Input has ended: every later read is the end too.
    ended: bool,
    /// Tasks waiting for a line to be queued.
    watchers: Waiters,
}

static STATE: Mutex<State> =
    Mutex::new(State { queue: VecDeque::new(), wanted: false, started: false, ended: false, watchers: Waiters::new() });
static WANTED: Condvar = Condvar::new();

fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Ask the reader thread for a line, starting it the first time.
fn want(state: &mut State) {
    if state.wanted {
        return;
    }
    state.wanted = true;
    if !state.started {
        state.started = true;
        let started = std::thread::Builder::new().name("roc-net-stdin".into()).spawn(read_lines);
        if let Err(err) = started {
            state.wanted = false;
            state.started = false;
            state.queue.push_back(Line::Failed(err));
        }
    }
    WANTED.notify_one();
}

fn read_lines() {
    loop {
        {
            let mut guard = state();
            while !guard.wanted {
                guard = WANTED.wait(guard).unwrap_or_else(|poisoned| poisoned.into_inner());
            }
        }
        let line = read_line(&mut io::stdin().lock());
        let mut guard = state();
        guard.wanted = false;
        let ended = matches!(line, Line::End);
        guard.queue.push_back(line);
        guard.ended |= ended;
        guard.watchers.wake_all();
        if ended {
            return;
        }
    }
}

/// One line from `input`, keeping at most [`MAX_LINE`] bytes of it.
fn read_line(input: &mut impl BufRead) -> Line {
    let mut line = Vec::new();
    let mut too_long = false;
    loop {
        let buf = match input.fill_buf() {
            Ok(buf) => buf,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Line::Failed(err),
        };
        if buf.is_empty() {
            // The end: a last line without a line ending still counts.
            if line.is_empty() && !too_long {
                return Line::End;
            }
            break;
        }
        let (part, found_end) = match buf.iter().position(|&b| b == b'\n') {
            Some(at) => (&buf[..at], true),
            None => (buf, false),
        };
        if !too_long {
            // One byte over the limit is kept: it may be the `\r` of a
            // `\r\n`, which doesn't count. The limit applies once it's off.
            if line.len() + part.len() > MAX_LINE + 1 {
                too_long = true;
                line = Vec::new();
            } else {
                line.extend_from_slice(part);
            }
        }
        let used = part.len() + usize::from(found_end);
        input.consume(used);
        if found_end {
            break;
        }
    }
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    if too_long || line.len() > MAX_LINE {
        return Line::TooLong;
    }
    match String::from_utf8(line) {
        Ok(text) => Line::Text(text),
        Err(_) => Line::Failed(io::Error::new(io::ErrorKind::InvalidData, "stream did not contain valid UTF-8")),
    }
}

/// The next line if one has been read, asking for another if not.
pub fn try_line() -> Option<Line> {
    let mut state = state();
    if let Some(line) = state.queue.pop_front() {
        return Some(line);
    }
    if state.ended {
        return Some(Line::End);
    }
    want(&mut state);
    None
}

/// Whether a `Select` must wait for stdin (see [`watch`]).
pub enum Watch {
    Ready,
    /// Registered under this id (remove with [`unwatch`]).
    Waiting(u64),
}

/// For a `Select` (or a blocking read) that found no line: register `waker`
/// to be woken when one is queued, unless one already is.
pub fn watch(waker: &TaskWaker) -> Watch {
    let mut state = state();
    if !state.queue.is_empty() || state.ended {
        return Watch::Ready;
    }
    want(&mut state);
    Watch::Waiting(state.watchers.add_waker(waker.clone()))
}

pub fn unwatch(id: u64) {
    state().watchers.remove(id);
}

/// The next line, waiting for it without holding up other tasks; fails
/// with `Cancelled` if the task is cancelled first (the line, once read,
/// goes to the next reader).
pub fn next_line() -> Line {
    loop {
        if let Some(line) = try_line() {
            return line;
        }
        let Some(wait) = sched::begin_multi_wait() else {
            // Not in a task (never the case for Roc code): poll again shortly.
            std::thread::sleep(Duration::from_millis(1));
            continue;
        };
        match watch(&wait.waker()) {
            Watch::Ready => wait.abandon(),
            Watch::Waiting(id) => {
                let woke = wait.wait(None);
                unwatch(id);
                if woke == Woke::Cancelled {
                    return Line::Failed(sched::cancelled());
                }
            }
        }
    }
}
