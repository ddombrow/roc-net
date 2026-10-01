//! `Pipe.copy_both!`: a proxy's two directions, copied by the host so the
//! bytes never become Roc lists.
//!
//! A to B runs on the calling task and B to A on a helper task, each a
//! read-then-write loop over the same socket operations Roc's `read!` and
//! `write!` use (so timeouts, TLS and cancellation behave the same). The
//! helper borrows both sockets, so the caller waits for it before returning
//! in every case, which keeps the Roc handles, and so the sockets, alive
//! until then.
//!
//! - One side's end of stream shuts down writing on the other, and the other
//!   direction carries on (a half-close).
//! - The first error aborts both streams (see [`abort`]), which ends the
//!   other direction's waits too; later errors (usually caused by that) are
//!   dropped. Aborting, not closing: a clean end (FIN, or TLS close_notify)
//!   after a failure would tell the peer it had received everything. Except
//!   a stream whose incoming direction already ended cleanly: what it was
//!   sent is complete, and a reset would make its peer's kernel discard
//!   whatever it hadn't read yet (a backend's whole response, when the
//!   client is slow to read it and then the session times out).
//! - A read that times out tries again if the other direction moved in the
//!   meantime, or is in the middle of a write, so a session is idle only
//!   when neither direction is.
//! - A direction holds its buffer only while data is flowing: it waits for
//!   the next data without one, so idle sessions cost no buffer memory. The
//!   buffer starts small and grows during bulk transfers. Buffers (and on
//!   Linux, pipes) given back wait in a small per-thread pool for the next
//!   direction that needs one, since allocating per message would cost more
//!   than a small message's copy.
//!
//! On Linux, a direction between two plain sockets (TCP or Unix) moves the
//! bytes with `splice` through a pipe, so they never reach this process's
//! memory. Anything else, or a kernel that refuses, copies through a buffer.

use std::io::{self, Read};
use std::net::Shutdown;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::sched::Woke;
use crate::sockets::Socket;

/// A direction's buffer while data flows: one TLS record's worth to start
/// with, grown to `LARGE_BUFFER` once a read fills it (a bulk transfer, where
/// bigger reads cost less CPU per byte).
const BUFFER: usize = 16 * 1024;
const LARGE_BUFFER: usize = 64 * 1024;

#[derive(Clone, Copy)]
pub enum Side {
    A,
    B,
}

impl Side {
    fn index(self) -> usize {
        match self {
            Side::A => 0,
            Side::B => 1,
        }
    }
}

pub enum CopyErr {
    Read(Side, io::Error),
    Write(Side, io::Error),
    /// The task running `copy_both` was cancelled.
    Cancelled,
    /// A `copy_to` with a deadline ran past it.
    MessageTimeout,
    /// No task could be started for the second direction.
    TaskLimit,
}

/// State both directions share.
struct Shared {
    /// Bumped each time either direction forwards bytes.
    progress: AtomicU64,
    /// How many directions are in the middle of a write.
    writing: AtomicU32,
    /// By side: the direction into that stream ended cleanly (its end of
    /// stream was passed on), so everything sent to it is complete.
    ended_into: [AtomicBool; 2],
    /// The first error, which is the one reported.
    first_err: Mutex<Option<CopyErr>>,
    /// When the whole copy must be done by (`copy_to` for a `Framing`
    /// reader's message), if ever.
    deadline: Option<Instant>,
}

impl Shared {
    fn new(deadline: Option<Instant>) -> Shared {
        Shared {
            progress: AtomicU64::new(0),
            writing: AtomicU32::new(0),
            ended_into: [AtomicBool::new(false), AtomicBool::new(false)],
            first_err: Mutex::new(None),
            deadline,
        }
    }

    fn past_deadline(&self) -> bool {
        self.deadline.is_some_and(|at| Instant::now() >= at)
    }

    /// Record `err` if it's the first, and if so end both streams (`a` and
    /// `b` are sides A and B): abort each, unless its incoming direction
    /// already ended cleanly; then only stop reading it, which wakes a
    /// reader without telling its peer anything.
    fn fail(&self, err: CopyErr, a: &Socket, b: &Socket) {
        let mut first = self.first_err.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if first.is_none() {
            *first = Some(err);
            drop(first);
            for (socket, side) in [(a, Side::A), (b, Side::B)] {
                if self.ended_into[side.index()].load(Ordering::Acquire) {
                    stop_reading(socket);
                } else {
                    abort(socket);
                }
            }
        }
    }

    /// The direction into `side` passed its end of stream on.
    fn ended_into(&self, side: Side) {
        self.ended_into[side.index()].store(true, Ordering::Release);
    }
}

/// A socket borrowed by the helper task.
#[derive(Clone, Copy)]
struct Borrowed(*const Socket);

// Sockets are used from several tasks at once already (a reader and a
// writer); `copy_both` keeps the borrow alive until the helper finishes.
unsafe impl Send for Borrowed {}

const _: () = {
    const fn sync<T: Sync>() {}
    sync::<Socket>()
};

fn not_a_stream() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "copy_both! works on streams (TCP, Unix, TLS)")
}

/// Give up on a stream partway through: a TCP reset, and for TLS no
/// close_notify, so the peer sees an error rather than a clean (and possibly
/// truncated) end. Unix sockets have no reset, so they're just closed.
pub fn abort(socket: &Socket) {
    match socket {
        Socket::TcpStream(s) => s.abort(),
        Socket::Tls(s) => s.abort(),
        Socket::Noise(s) => s.wire().abort(),
        Socket::UnixStream(s) => {
            let _ = s.io.shutdown(Shutdown::Both);
        }
        _ => {}
    }
}

/// Shut down reading only: wakes a task waiting to read, and sends the peer
/// nothing (no FIN, reset or close_notify).
fn stop_reading(socket: &Socket) {
    let _ = match socket {
        Socket::TcpStream(s) => s.io.shutdown(Shutdown::Read),
        Socket::UnixStream(s) => s.io.shutdown(Shutdown::Read),
        Socket::Tls(s) => s.shutdown(Shutdown::Read),
        _ => Ok(()),
    };
}

/// Wait, without a buffer, until a read of `socket` may find something:
/// data, the end of the stream, or an error. Under the read timeout, and no
/// later than `by`. It checks before waiting (see `Conn::wait_readable`):
/// data that arrived before the copy began must not be missed.
fn wait_readable(socket: &Socket, by: Option<Instant>) -> io::Result<()> {
    match socket {
        Socket::TcpStream(s) => s.wait_readable(by),
        Socket::UnixStream(s) => s.wait_readable(by),
        // Waits for ciphertext (or does the handshake), and returns at once
        // if there's plaintext already.
        Socket::Tls(s) => s.fill_by(by),
        _ => Err(not_a_stream()),
    }
}

/// Read what has arrived without waiting: `None` if nothing has.
fn read_now(socket: &Socket, buf: &mut [u8]) -> io::Result<Option<usize>> {
    fn once(read: impl Fn(&mut [u8]) -> io::Result<usize>, buf: &mut [u8]) -> io::Result<Option<usize>> {
        loop {
            match read(buf) {
                Ok(n) => return Ok(Some(n)),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(None),
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(err) => return Err(err),
            }
        }
    }
    match socket {
        Socket::TcpStream(s) => once(|buf| (&mut &s.io).read(buf), buf),
        Socket::UnixStream(s) => once(|buf| (&mut &s.io).read(buf), buf),
        Socket::Tls(s) => loop {
            if let Some(n) = s.try_read(buf)? {
                return Ok(Some(n));
            }
            if !s.fill_now()? {
                return Ok(None);
            }
        },
        _ => Err(not_a_stream()),
    }
}

fn write_all(socket: &Socket, data: &[u8]) -> io::Result<()> {
    match socket {
        Socket::TcpStream(s) => s.write_all(data),
        Socket::UnixStream(s) => s.write_all_with(data, |s, data| io::Write::write(&mut &*s, data)),
        Socket::Tls(s) => s.write_all(data),
        _ => Err(not_a_stream()),
    }
}

fn shutdown_write(socket: &Socket) {
    // Best effort: the peer may be gone already.
    let _ = match socket {
        Socket::TcpStream(s) => s.io.shutdown(Shutdown::Write),
        Socket::UnixStream(s) => s.io.shutdown(Shutdown::Write),
        Socket::Tls(s) => s.shutdown(Shutdown::Write),
        _ => Ok(()),
    };
}

/// Buffers given back by directions that went idle, per worker thread.
mod spare {
    use std::cell::RefCell;

    use super::BUFFER;

    /// At most this many wait per thread (half a megabyte).
    const KEEP: usize = 32;

    thread_local! {
        static BUFFERS: RefCell<Vec<Vec<u8>>> = const { RefCell::new(Vec::new()) };
    }

    /// A `BUFFER`-sized buffer, reused if one is spare. Its contents are
    /// whatever was last read into it, which reads overwrite.
    // Never inlined, like every thread-local access (see `sched.rs`): a
    // task may resume on another thread, and an inlined access could reuse
    // the previous thread's pool.
    #[inline(never)]
    pub fn buffer() -> Vec<u8> {
        BUFFERS.with(|spare| spare.borrow_mut().pop()).unwrap_or_else(|| vec![0; BUFFER])
    }

    /// Keep `buffer` for reuse, unless it grew (a bulk transfer's) or
    /// enough are spare already.
    #[inline(never)]
    pub fn give_back(buffer: Vec<u8>) {
        if buffer.len() == BUFFER {
            BUFFERS.with(|spare| {
                let mut spare = spare.borrow_mut();
                if spare.len() < KEEP {
                    spare.push(buffer);
                }
            });
        }
    }
}

/// A read-side error as reported: a cancelled wait is `Cancelled`, not a
/// failure of either stream.
fn read_err(side: Side, err: io::Error) -> CopyErr {
    if crate::sched::is_cancelled_error(&err) {
        CopyErr::Cancelled
    } else {
        CopyErr::Read(side, err)
    }
}

fn write_err(side: Side, err: io::Error) -> CopyErr {
    if crate::sched::is_cancelled_error(&err) {
        CopyErr::Cancelled
    } else {
        CopyErr::Write(side, err)
    }
}

/// Wait for `from` to have something to read, retrying a timeout while the
/// session isn't idle: the other direction moved during the wait (`seen` is
/// the progress count when it began), or is writing now.
fn wait_for_data(from: &Socket, from_side: Side, shared: &Shared) -> Result<(), CopyErr> {
    loop {
        let seen = shared.progress.load(Ordering::Acquire);
        match wait_readable(from, shared.deadline) {
            Ok(()) => return Ok(()),
            Err(err) if err.kind() == io::ErrorKind::TimedOut && shared.past_deadline() => {
                return Err(CopyErr::MessageTimeout)
            }
            Err(err)
                if err.kind() == io::ErrorKind::TimedOut
                    && (shared.progress.load(Ordering::Acquire) != seen
                        || shared.writing.load(Ordering::Acquire) > 0) => {}
            Err(err) => return Err(read_err(from_side, err)),
        }
    }
}

/// Run `write` counted as writing, and as progress once done.
fn writing<R>(shared: &Shared, write: impl FnOnce() -> R) -> R {
    shared.writing.fetch_add(1, Ordering::AcqRel);
    let result = write();
    shared.writing.fetch_sub(1, Ordering::AcqRel);
    shared.progress.fetch_add(1, Ordering::AcqRel);
    result
}

/// Why a one-way copy stopped (errors aside).
#[derive(PartialEq)]
enum Ended {
    /// `from` ended.
    Eof,
    /// `total` reached `end_at`.
    Limit,
}

/// How much the next read may take: all it can, or with `end_at`, no more
/// than is left to copy. Never reading past the limit is what leaves the
/// stream usable for whatever follows (for TLS, rustls keeps the rest of a
/// record for the next read).
fn cap(len: usize, total: u64, end_at: Option<u64>) -> usize {
    match end_at {
        None => len,
        Some(end) => (end.saturating_sub(total)).min(len as u64) as usize,
    }
}

/// Copy `from` to `to` through a buffer until `from` ends or, with
/// `end_at`, until `total` (the bytes copied, counting any before this
/// call) reaches it. The buffer exists only while data is flowing, and
/// grows while reads fill it.
fn buffered(from: &Socket, to: &Socket, sides: (Side, Side), shared: &Shared, total: &mut u64, end_at: Option<u64>) -> Result<Ended, CopyErr> {
    let mut buf: Vec<u8> = Vec::new();
    loop {
        if end_at.is_some_and(|end| *total >= end) {
            spare::give_back(buf);
            return Ok(Ended::Limit);
        }
        // Checked between chunks too: a peer sending steadily, but not fast
        // enough, never makes a wait time out.
        if shared.past_deadline() {
            return Err(CopyErr::MessageTimeout);
        }
        if buf.is_empty() {
            wait_for_data(from, sides.0, shared)?;
            buf = spare::buffer();
        }
        let room = cap(buf.len(), *total, end_at);
        match read_now(from, &mut buf[..room]).map_err(|err| read_err(sides.0, err))? {
            Some(0) => {
                spare::give_back(buf);
                return Ok(Ended::Eof);
            }
            Some(n) => {
                writing(shared, || write_all(to, &buf[..n])).map_err(|err| write_err(sides.1, err))?;
                *total += n as u64;
                if n == buf.len() && n < LARGE_BUFFER {
                    buf.resize(LARGE_BUFFER, 0);
                }
            }
            // Drained: give the buffer back while waiting for more.
            None => spare::give_back(std::mem::take(&mut buf)),
        }
    }
}

/// The one-way loop both `copy_both` and `copy_to` use: `splice` where it
/// can (Linux, plain sockets), else through a buffer.
fn one_way(from: &Socket, to: &Socket, sides: (Side, Side), shared: &Shared, total: &mut u64, end_at: Option<u64>) -> Result<Ended, CopyErr> {
    #[cfg(target_os = "linux")]
    if let Some(result) = splice::copy(from, to, sides, shared, total, end_at) {
        return result;
    }
    buffered(from, to, sides, shared, total, end_at)
}

/// Copy `from` to `to` until `from` ends; returns the bytes copied. On an
/// error, aborts both streams and records the error if it's the first.
fn direction(from: &Socket, to: &Socket, sides: (Side, Side), shared: &Shared) -> u64 {
    let mut total = 0;
    match one_way(from, to, sides, shared, &mut total, None) {
        // Pass the end of stream on.
        Ok(_) => {
            shutdown_write(to);
            shared.ended_into(sides.1);
        }
        Err(err) => match sides.0 {
            Side::A => shared.fail(err, from, to),
            Side::B => shared.fail(err, to, from),
        },
    }
    total
}

/// `Pipe.copy_to!`: write `prefix` to `to`, then copy `from` to `to` until
/// `from` ends, or with `limit`, exactly that many more bytes, never reading
/// past them, all by `deadline` if there is one. Returns the bytes `to`
/// accepted (the prefix included; the peer may have received fewer, and a
/// write that failed partway isn't counted) and the error, if any; an early
/// end with a limit is `Read(UnexpectedEof)`. Unlike `copy_both`, it
/// neither shuts down nor aborts anything: the caller does what fits. On
/// the calling task; with nothing going the other way, read timeouts apply
/// as they are.
pub fn copy_to(from: &Socket, to: &Socket, prefix: &[u8], limit: Option<u64>, deadline: Option<Instant>) -> (u64, Option<CopyErr>) {
    let shared = Shared::new(deadline);
    let mut total = 0;
    if !prefix.is_empty() {
        if let Err(err) = write_all(to, prefix) {
            return (0, Some(write_err(Side::B, err)));
        }
        total = prefix.len() as u64;
    }
    let end_at = limit.map(|n| total + n);
    match one_way(from, to, (Side::A, Side::B), &shared, &mut total, end_at) {
        Ok(Ended::Eof) if end_at.is_some() => (total, Some(CopyErr::Read(Side::A, io::ErrorKind::UnexpectedEof.into()))),
        Ok(_) => (total, None),
        Err(err) => (total, Some(err)),
    }
}

/// Copy between `a` and `b` both ways until both directions end (see the
/// module docs). Returns the bytes each side accepted, A to B and B to A
/// (counted even when the copy failed; the peers may have received fewer),
/// and the first error, if any.
pub fn copy_both(a: &Socket, b: &Socket) -> (u64, u64, Option<CopyErr>) {
    let shared = Arc::new(Shared::new(None));
    let b_to_a = Arc::new(AtomicU64::new(0));
    let (ra, rb) = (Borrowed(a), Borrowed(b));
    let helper = {
        let shared = shared.clone();
        let b_to_a = b_to_a.clone();
        crate::tasks::spawn_host(move || {
            let (ra, rb) = (ra, rb);
            // Safety: `copy_both` waits for this task before its borrows end.
            let (a, b) = unsafe { (&*ra.0, &*rb.0) };
            b_to_a.store(direction(b, a, (Side::B, Side::A), &shared), Ordering::Release);
        })
    };
    let Some(helper) = helper else { return (0, 0, Some(CopyErr::TaskLimit)) };
    let a_to_b = direction(a, b, (Side::A, Side::B), &shared);
    if helper.wait_finished(true) == Woke::Cancelled {
        // Cancelled while B to A carries on: stop it, and wait regardless,
        // since it borrows the sockets.
        shared.fail(CopyErr::Cancelled, a, b);
        helper.wait_finished(false);
    }
    let first = shared.first_err.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
    (a_to_b, b_to_a.load(Ordering::Acquire), first)
}

#[cfg(target_os = "linux")]
mod splice {
    //! Zero-copy for plain sockets: socket to pipe to socket with `splice`.

    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

    use super::{cap, read_err, wait_for_data, write_err, writing, CopyErr, Ended, Shared, Side};
    use crate::sockets::Socket;

    /// How much to move per `splice`: a default pipe's capacity.
    const CHUNK: usize = 64 * 1024;

    /// The descriptor of a plain stream, which `splice` can use.
    fn plain_fd(socket: &Socket) -> Option<RawFd> {
        match socket {
            Socket::TcpStream(s) => Some(s.io.as_raw_fd()),
            Socket::UnixStream(s) => Some(s.io.as_raw_fd()),
            _ => None,
        }
    }

    /// Run `op` until it stops failing with `WouldBlock`, waiting for `socket`
    /// to be writable in between, under its write timeout, as its writes do.
    fn retry_write(socket: &Socket, mut op: impl FnMut() -> io::Result<usize>) -> io::Result<usize> {
        match socket {
            Socket::TcpStream(s) => s.retry(true, s.write_deadline(), |_| op()),
            Socket::UnixStream(s) => s.retry(true, s.write_deadline(), |_| op()),
            _ => unreachable!("only plain streams are spliced"),
        }
    }

    fn splice(from: RawFd, to: RawFd, len: usize) -> io::Result<usize> {
        loop {
            let flags = libc::SPLICE_F_MOVE | libc::SPLICE_F_NONBLOCK;
            let n = unsafe { libc::splice(from, std::ptr::null_mut(), to, std::ptr::null_mut(), len, flags) };
            if n >= 0 {
                return Ok(n as usize);
            }
            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }

    /// Empty pipes given back by directions that went idle, per worker
    /// thread, at most `KEEP_PIPES` (two descriptors each).
    const KEEP_PIPES: usize = 16;

    thread_local! {
        static PIPES: std::cell::RefCell<Vec<(OwnedFd, OwnedFd)>> = const { std::cell::RefCell::new(Vec::new()) };
    }

    /// A pipe, reused if one is spare.
    // Never inlined, like every thread-local access (see `sched.rs`): a
    // task may resume on another thread, and an inlined access could reuse
    // the previous thread's pool.
    #[inline(never)]
    fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
        match PIPES.with(|spare| spare.borrow_mut().pop()) {
            Some(ends) => Ok(ends),
            None => new_pipe(),
        }
    }

    /// Keep an empty pipe for reuse, unless enough are spare already.
    #[inline(never)]
    fn give_back(ends: (OwnedFd, OwnedFd)) {
        PIPES.with(|spare| {
            let mut spare = spare.borrow_mut();
            if spare.len() < KEEP_PIPES {
                spare.push(ends);
            }
        });
    }

    /// `(read end, write end)`, both non-blocking.
    fn new_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
        let mut fds = [0; 2];
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
    }

    /// Whether `splice` refused the descriptors rather than failing on them.
    fn unsupported(err: &io::Error) -> bool {
        matches!(err.raw_os_error(), Some(libc::EINVAL | libc::ENOSYS | libc::EOPNOTSUPP))
    }

    /// Copy `from` to `to` with `splice`, like `buffered` (and under the
    /// same limit), with a pipe only while data flows (idle sessions keep no
    /// pipe, and so no extra descriptors; see `pipe`). `None` (with the pipe
    /// empty, so `total` is exact) if either isn't a plain stream, no pipe
    /// can be made, or the kernel won't splice them: the buffered copy
    /// carries on from there.
    pub fn copy(
        from: &Socket,
        to: &Socket,
        sides: (Side, Side),
        shared: &Shared,
        total: &mut u64,
        end_at: Option<u64>,
    ) -> Option<Result<Ended, CopyErr>> {
        let (from_fd, to_fd) = (plain_fd(from)?, plain_fd(to)?);
        let mut pipe_ends: Option<(OwnedFd, OwnedFd)> = None;
        // Bytes spliced by this call: a refusal before any means the kernel
        // won't splice these sockets at all.
        let mut spliced = 0;
        loop {
            if end_at.is_some_and(|end| *total >= end) {
                if let Some(ends) = pipe_ends.take() {
                    give_back(ends);
                }
                return Some(Ok(Ended::Limit));
            }
            if shared.past_deadline() {
                return Some(Err(CopyErr::MessageTimeout));
            }
            let (pipe_out, pipe_in) = match &pipe_ends {
                Some(ends) => ends,
                None => {
                    if let Err(err) = wait_for_data(from, sides.0, shared) {
                        return Some(Err(err));
                    }
                    // Out of descriptors, say.
                    pipe_ends.insert(pipe().ok()?)
                }
            };
            // The pipe is empty here, so `WouldBlock` means `from` has
            // nothing now.
            let n = match splice(from_fd, pipe_in.as_raw_fd(), cap(CHUNK, *total, end_at)) {
                Ok(n) => n,
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                    // Drained (the pipe is empty): give it back while waiting
                    // for more.
                    if let Some(ends) = pipe_ends.take() {
                        give_back(ends);
                    }
                    continue;
                }
                Err(err) if spliced == 0 && unsupported(&err) => return None,
                Err(err) => return Some(Err(read_err(sides.0, err))),
            };
            if n == 0 {
                if let Some(ends) = pipe_ends.take() {
                    give_back(ends);
                }
                return Some(Ok(Ended::Eof));
            }
            // Drain the pipe; with bytes in it, `WouldBlock` means `to` is
            // full.
            let drained = writing(shared, || {
                let mut left = n;
                while left > 0 {
                    match retry_write(to, || splice(pipe_out.as_raw_fd(), to_fd, left))? {
                        0 => return Err(io::ErrorKind::WriteZero.into()),
                        m => left -= m,
                    }
                }
                Ok(())
            });
            if let Err(err) = drained {
                return Some(Err(write_err(sides.1, err)));
            }
            *total += n as u64;
            spliced += n;
        }
    }
}
