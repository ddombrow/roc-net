//! Sockets owned by Roc through `Box(U64)` handles (see `resource.rs`).

use std::net::{TcpListener, TcpStream, UdpSocket};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::OnceLock;

use crate::resource::{Full, Reservation, ResourceHeap};

pub enum Socket {
    TcpListener(TcpListener),
    TcpStream(TcpStream),
    UnixListener(OwnedUnixListener),
    UnixStream(UnixStream),
    Udp(UdpSocket),
    TlsListener(TlsListener),
    Tls(crate::tls::TlsStream),
}

/// A TCP listener whose connections speak TLS with this configuration.
pub struct TlsListener {
    pub listener: TcpListener,
    pub config: std::sync::Arc<rustls::ServerConfig>,
    /// How long each accepted connection has to finish its handshake
    /// (0 means no limit).
    pub handshake_timeout_ms: u64,
}

/// A Unix listener that deletes its socket file when it closes, so the path
/// can be reused.
pub struct OwnedUnixListener {
    pub listener: UnixListener,
    pub path: PathBuf,
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
