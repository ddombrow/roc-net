//! Sockets owned by Roc through `Box(U64)` handles (see `resource.rs`).

use std::net::{TcpListener, TcpStream};
use std::sync::OnceLock;

use crate::resource::{Full, Reservation, ResourceHeap};

pub enum Socket {
    TcpListener(TcpListener),
    TcpStream(TcpStream),
}

fn heap() -> &'static ResourceHeap<Socket> {
    static HEAP: OnceLock<ResourceHeap<Socket>> = OnceLock::new();
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
pub unsafe fn listener<'a>(handle: *mut u64) -> Result<&'a TcpListener, String> {
    match unsafe { heap().get(handle) } {
        Ok(Socket::TcpListener(listener)) => Ok(listener),
        Ok(_) => Err("handle is not a TCP listener".into()),
        Err(_) => Err("invalid socket handle".into()),
    }
}

/// # Safety
/// The caller must own a live Roc reference to `handle` while using the result.
pub unsafe fn stream<'a>(handle: *mut u64) -> Result<&'a TcpStream, String> {
    match unsafe { heap().get(handle) } {
        Ok(Socket::TcpStream(stream)) => Ok(stream),
        Ok(_) => Err("handle is not a TCP stream".into()),
        Err(_) => Err("invalid socket handle".into()),
    }
}

/// Called by `roc_dealloc`. Returns true if `ptr` was a socket slot, which is
/// now closed and must not be freed as ordinary memory.
pub fn release(ptr: *mut std::ffi::c_void) -> bool {
    heap().release(ptr)
}
