//! Sockets owned by Roc through `Box(U64)` handles (see `resource.rs`).

use std::io::{self, Write};
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

use crate::resource::{Full, Reservation, ResourceHeap};
use crate::sched::IoReg;

pub enum Socket {
    TcpListener(Conn<TcpListener>, ServerTimeouts),
    TcpStream(Conn<TcpStream>),
    UnixListener(OwnedUnixListener),
    UnixStream(Conn<UnixStream>),
    Udp(Conn<UdpSocket>),
    TlsListener(TlsListener),
    /// Boxed: rustls's state is about a kilobyte, and every slot in the
    /// socket heap is sized for the largest kind of socket, so inline it would
    /// make each of the (by default) 16,384 slots that big.
    Tls(Box<crate::tls::TlsStream>),
}

/// A non-blocking socket, and what's needed to wait for it: its event-queue
/// registrations and its read and write timeouts (in milliseconds; 0 means
/// none). Operations that would block suspend the task instead (see
/// `sched.rs`), until the socket is ready or the timeout passes.
pub struct Conn<T> {
    pub io: T,
    reg: IoReg,
    read_ms: AtomicU64,
    write_ms: AtomicU64,
}

impl<T: AsRawFd> Conn<T> {
    /// `io` must already be non-blocking.
    pub fn new(io: T) -> Self {
        Conn {
            io,
            reg: IoReg::default(),
            read_ms: AtomicU64::new(0),
            write_ms: AtomicU64::new(0),
        }
    }

    pub fn set_read_timeout_ms(&self, ms: u64) {
        self.read_ms.store(ms, Ordering::Relaxed);
    }

    pub fn set_write_timeout_ms(&self, ms: u64) {
        self.write_ms.store(ms, Ordering::Relaxed);
    }

    pub fn timeouts(&self) -> ServerTimeouts {
        ServerTimeouts { idle_ms: self.read_ms.load(Ordering::Relaxed), write_ms: self.write_ms.load(Ordering::Relaxed) }
    }

    /// When a read starting now times out.
    pub fn read_deadline(&self) -> Option<Instant> {
        deadline_after(self.read_ms.load(Ordering::Relaxed))
    }

    pub fn write_deadline(&self) -> Option<Instant> {
        deadline_after(self.write_ms.load(Ordering::Relaxed))
    }

    /// Run `op` until it does something other than `WouldBlock`, waiting in
    /// between for the socket to be readable (or `writable`), until
    /// `deadline`.
    pub fn retry<R>(&self, writable: bool, deadline: Option<Instant>, mut op: impl FnMut(&T) -> io::Result<R>) -> io::Result<R> {
        loop {
            match op(&self.io) {
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                    crate::sched::wait_io(self.io.as_raw_fd(), &self.reg, writable, deadline)?
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                result => {
                    if result.is_ok() {
                        crate::sched::consume_budget();
                    }
                    return result;
                }
            }
        }
    }

    /// A read-like operation, under the read timeout.
    pub fn read_with<R>(&self, op: impl FnMut(&T) -> io::Result<R>) -> io::Result<R> {
        self.retry(false, self.read_deadline(), op)
    }

    /// Write all of `data` with `write`. The write timeout limits how long it
    /// may go without progress, like `SO_SNDTIMEO`, rather than the whole
    /// write.
    pub fn write_all_with(&self, mut data: &[u8], mut write: impl FnMut(&T, &[u8]) -> io::Result<usize>) -> io::Result<()> {
        while !data.is_empty() {
            let written = self.retry(true, self.write_deadline(), |io| write(io, data))?;
            if written == 0 {
                return Err(io::ErrorKind::WriteZero.into());
            }
            data = &data[written..];
        }
        Ok(())
    }

    /// The descriptor and scheduling state, for waiting on it alongside
    /// other sources (`Select`).
    pub fn io_parts(&self) -> (std::os::fd::RawFd, &IoReg) {
        (self.io.as_raw_fd(), &self.reg)
    }

    /// End a TCP connection with a reset (RST) now, so the peer sees an
    /// error, not a clean end of stream: for giving up partway through, when
    /// a clean end would pass truncated data off as complete. The descriptor
    /// stays open (Roc may still hold it) and later operations on it fail;
    /// tasks waiting on it wake. Best effort: if the reset can't be sent,
    /// both directions are shut down instead.
    pub fn abort(&self) {
        let fd = self.io.as_raw_fd();
        // With a zero linger time, disconnecting resets instead of sending FIN.
        let linger = libc::linger { l_onoff: 1, l_linger: 0 };
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_LINGER,
                &linger as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::linger>() as libc::socklen_t,
            )
        };
        if disconnect(fd) != 0 {
            unsafe { libc::shutdown(fd, libc::SHUT_RDWR) };
        }
    }

    /// Wait until the socket has something to read (data or the end of the
    /// stream), under the read timeout, without reading it; fails with the
    /// socket's error, if it has one. Checks first and waits only if there's
    /// nothing yet, like every operation here: readiness events are
    /// edge-triggered, so data that arrived before a wait began (say, while
    /// the socket was watched for a connect) brings no new event, and waiting
    /// first would wait for more data that may never come.
    ///
    /// With `by`, it gives up with `TimedOut` then too, if that's sooner than
    /// the read timeout.
    pub fn wait_readable(&self, by: Option<Instant>) -> io::Result<()> {
        self.retry(false, earliest(self.read_deadline(), by), |io| {
            let mut byte = 0u8;
            let flags = libc::MSG_PEEK;
            let n = unsafe { libc::recv(io.as_raw_fd(), &mut byte as *mut u8 as *mut libc::c_void, 1, flags) };
            if n < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        })
    }

    /// Wait until the socket is writable (say, a non-blocking connect has
    /// finished), until `deadline`.
    pub fn wait_writable(&self, deadline: Option<Instant>) -> io::Result<()> {
        crate::sched::wait_io(self.io.as_raw_fd(), &self.reg, true, deadline)
    }
}

impl Conn<TcpStream> {
    pub fn write_all(&self, data: &[u8]) -> io::Result<()> {
        self.write_all_with(data, |s, data| (&mut &*s).write(data))
    }
}

/// The sooner of two deadlines (`None` being never).
pub fn earliest(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

/// Disconnect a socket without closing its descriptor: `connect` to
/// `AF_UNSPEC` on Linux, `disconnectx` on macOS. 0 on success.
#[cfg(target_os = "linux")]
fn disconnect(fd: std::os::fd::RawFd) -> i32 {
    let mut addr: libc::sockaddr = unsafe { std::mem::zeroed() };
    addr.sa_family = libc::AF_UNSPEC as libc::sa_family_t;
    unsafe { libc::connect(fd, &addr, std::mem::size_of::<libc::sockaddr>() as libc::socklen_t) }
}

#[cfg(target_os = "macos")]
fn disconnect(fd: std::os::fd::RawFd) -> i32 {
    unsafe extern "C" {
        fn disconnectx(fd: libc::c_int, association: u32, connection: u32) -> libc::c_int;
    }
    // SAE_ASSOCID_ANY, SAE_CONNID_ANY.
    unsafe { disconnectx(fd, 0, 0) }
}

/// The moment `ms` milliseconds from now; 0 means no deadline. So does a
/// timeout too long to represent as a moment, which could never be reached
/// anyway. (`checked_add`, because `Instant + ...` would panic and, with
/// `panic = "abort"`, end the program.)
pub fn deadline_after(ms: u64) -> Option<Instant> {
    if ms == 0 {
        return None;
    }
    Instant::now().checked_add(std::time::Duration::from_millis(ms))
}

/// Run `f` with this thread's read buffer, at least `len` bytes long.
///
/// Reusing one buffer per thread avoids allocating and zeroing a fresh one on
/// every read (then only the bytes that arrived are copied into the Roc list
/// returned). That per-read allocate-and-zero cost 30-60% extra CPU under
/// concurrent load with musl, whose memset is slower than glibc's. It grows
/// to the largest read a thread has asked for.
///
/// Tasks share their worker's buffer, so `f` must not wait (suspending
/// would let another task on the thread ask for the buffer while it's
/// borrowed): read with it only once the socket is ready.
pub fn with_scratch<T>(len: usize, f: impl FnOnce(&mut [u8]) -> T) -> T {
    thread_local! {
        static SCRATCH: std::cell::RefCell<Vec<u8>> = const { std::cell::RefCell::new(Vec::new()) };
    }
    SCRATCH.with(|scratch| {
        let mut scratch = scratch.borrow_mut();
        if scratch.len() < len {
            scratch.resize(len, 0);
        }
        f(&mut scratch[..len])
    })
}

/// A TCP listener whose connections speak TLS with this configuration.
pub struct TlsListener {
    pub listener: Conn<TcpListener>,
    pub config: std::sync::Arc<rustls::ServerConfig>,
    /// How long each accepted connection has to finish its handshake
    /// (0 means no limit).
    pub handshake_timeout_ms: u64,
    /// Timeouts for after the handshake.
    pub timeouts: ServerTimeouts,
}

/// A Unix listener that deletes its socket file when it closes, so the path
/// can be reused.
pub struct OwnedUnixListener {
    pub listener: Conn<UnixListener>,
    pub path: PathBuf,
    pub timeouts: ServerTimeouts,
}

/// Read and write timeouts a listener puts on every stream it accepts, so a
/// client that goes quiet (or stops reading) can't hold a server task
/// forever. In milliseconds; 0 means none.
#[derive(Clone, Copy)]
pub struct ServerTimeouts {
    pub idle_ms: u64,
    pub write_ms: u64,
}

impl ServerTimeouts {
    /// Apply to a newly accepted stream.
    pub fn apply<T: AsRawFd>(self, stream: &Conn<T>) {
        stream.set_read_timeout_ms(self.idle_ms);
        stream.set_write_timeout_ms(self.write_ms);
    }
}

impl Drop for OwnedUnixListener {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

static HEAP: OnceLock<ResourceHeap<Socket>> = OnceLock::new();

fn heap() -> &'static ResourceHeap<Socket> {
    HEAP.get_or_init(|| ResourceHeap::new(crate::limits::max_sockets()))
}

/// Claim a slot for a new socket, or fail if the limit is reached.
pub fn try_reserve() -> Result<Reservation<'static, Socket>, Full> {
    heap().try_reserve()
}

/// Claim a slot for a new socket, waiting for one to be released if needed;
/// `None` if the waiting task is cancelled.
pub fn reserve() -> Option<Reservation<'static, Socket>> {
    heap().reserve()
}

impl Socket {
    /// For a `Select` about to wait for this socket to become readable: when
    /// the wait must end anyway, as a blocking read of it would. That's the
    /// stream's read timeout, counted from now, or for a TLS stream still in
    /// its handshake, the handshake deadline if sooner. Listeners have none.
    pub fn read_wait_deadline(&self) -> Option<Instant> {
        let conn_deadline = match self {
            Socket::TcpStream(s) => s.read_deadline(),
            Socket::UnixStream(s) => s.read_deadline(),
            Socket::Udp(s) => s.read_deadline(),
            Socket::Tls(s) => s.conn().read_deadline(),
            _ => None,
        };
        let handshake = match self {
            Socket::Tls(s) => s.pending_handshake_deadline(),
            _ => None,
        };
        match (conn_deadline, handshake) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    /// The descriptor and scheduling state to wait on for this socket.
    pub fn io_parts(&self) -> (std::os::fd::RawFd, &IoReg) {
        match self {
            Socket::TcpListener(s, _) => s.io_parts(),
            Socket::TcpStream(s) => s.io_parts(),
            Socket::UnixListener(s) => s.listener.io_parts(),
            Socket::UnixStream(s) => s.io_parts(),
            Socket::Udp(s) => s.io_parts(),
            Socket::TlsListener(s) => s.listener.io_parts(),
            Socket::Tls(s) => s.conn().io_parts(),
        }
    }
}

/// # Safety
/// The caller must own a live Roc reference to `handle` while using the result.
pub unsafe fn get<'a>(handle: *mut u64) -> Option<&'a Socket> {
    unsafe { heap().get(handle) }.ok()
}

/// Called by `roc_dealloc`. Returns true if `ptr` was a socket slot, which is
/// now closed and must not be freed as ordinary memory.
pub fn release(ptr: *mut std::ffi::c_void) -> bool {
    // Don't create the heap just to learn a pointer isn't in it.
    HEAP.get().is_some_and(|heap| heap.release(ptr))
}
