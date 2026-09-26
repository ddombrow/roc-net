//! Sockets owned by Roc through `Box(U64)` handles (see `resource.rs`).

use std::net::{TcpListener, TcpStream, UdpSocket};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::OnceLock;

use crate::resource::{Full, Reservation, ResourceHeap};

pub enum Socket {
    TcpListener(TcpListener, ServerTimeouts),
    TcpStream(TcpStream),
    UnixListener(OwnedUnixListener),
    UnixStream(UnixStream),
    Udp(UdpSocket),
    TlsListener(TlsListener),
    /// Boxed: rustls's state is about a kilobyte, and every slot in the
    /// socket heap is sized for the largest kind of socket, so inline it would
    /// make each of the (by default) 16,384 slots that big.
    Tls(Box<crate::tls::TlsStream>),
}

/// A TCP listener whose connections speak TLS with this configuration.
pub struct TlsListener {
    pub listener: TcpListener,
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
    pub listener: UnixListener,
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
    /// Apply to a newly accepted stream's socket.
    pub fn apply(self, stream: &TcpStream) -> std::io::Result<()> {
        stream.set_read_timeout(Self::duration(self.idle_ms))?;
        stream.set_write_timeout(Self::duration(self.write_ms))
    }

    pub fn apply_unix(self, stream: &UnixStream) -> std::io::Result<()> {
        stream.set_read_timeout(Self::duration(self.idle_ms))?;
        stream.set_write_timeout(Self::duration(self.write_ms))
    }

    fn duration(ms: u64) -> Option<std::time::Duration> {
        (ms > 0).then(|| std::time::Duration::from_millis(ms))
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

/// Claim a slot for a new socket, waiting for one to be released if needed.
pub fn reserve() -> Reservation<'static, Socket> {
    heap().reserve()
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
