//! TCP hosted functions and the mapping from Rust I/O errors to Roc's `IOErr`.

use std::io::{self, Read, Write};
use std::mem::ManuallyDrop;
use std::net::{Shutdown, TcpListener, TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::roc_host;
use crate::roc_platform_abi::{
    decref_box_with, HostIOErr, HostIOErrPayload, HostIOErrTag, HostTcpAcceptResult,
    HostTcpAcceptResultPayload, HostTcpAcceptResultTag, HostTcpConnectResult, HostTcpListenResult,
    HostTcpListenResultPayload, HostTcpListenResultTag, HostTcpListenerLocalAddrResult,
    HostTcpListenerLocalAddrResultPayload, HostTcpListenerLocalAddrResultTag,
    HostTcpLocalAddrResult, HostTcpPeerAddrResult, HostTcpReadResult, HostTcpReadResultPayload,
    HostTcpReadResultTag, HostTcpSetNodelayResult, HostTcpSetNodelayResultPayload,
    HostTcpSetNodelayResultTag, HostTcpSetTimeoutResult, HostTcpShutdownResult,
    HostTcpWriteResult, IOErr, IOErrPayload, IOErrTag, RocBox, RocListWith, RocStr,
};
use crate::sockets::{self, Socket};

/// Largest single read buffer, so a huge `max` from Roc cannot force a huge allocation.
const MAX_READ_BYTES: u64 = 64 * 1024;

/// A failed network operation, before conversion to Roc's `IOErr`.
pub enum NetErr {
    Io(io::Error),
    TooManySockets,
    Other(String),
}

impl From<io::Error> for NetErr {
    fn from(err: io::Error) -> Self {
        NetErr::Io(err)
    }
}

/// Builds a Roc `IOErr` value. The glue emits identical copies of that type
/// (`IOErr`, `HostIOErr`) for different results, so this is a macro over the
/// type names rather than a function.
macro_rules! io_err {
    ($ty:ident, $payload:ident, $tag:ident, $err:expr) => {{
        use std::io::ErrorKind as K;
        let unit = |tag| $ty { payload: $payload { addr_in_use: [] }, tag };
        let other = |message: String| $ty {
            payload: $payload { other: ManuallyDrop::new(RocStr::from_str(&message, roc_host())) },
            tag: $tag::Other,
        };
        match $err {
            NetErr::TooManySockets => unit($tag::TooManySockets),
            NetErr::Other(message) => other(message),
            NetErr::Io(err) => match err.kind() {
                K::AddrInUse => unit($tag::AddrInUse),
                K::AddrNotAvailable => unit($tag::AddrNotAvailable),
                K::BrokenPipe => unit($tag::BrokenPipe),
                K::ConnectionAborted => unit($tag::ConnectionAborted),
                K::ConnectionRefused => unit($tag::ConnectionRefused),
                K::ConnectionReset => unit($tag::ConnectionReset),
                K::Interrupted => unit($tag::Interrupted),
                K::InvalidInput => unit($tag::InvalidInput),
                K::NotConnected => unit($tag::NotConnected),
                K::NotFound => unit($tag::NotFound),
                K::PermissionDenied => unit($tag::PermissionDenied),
                // Sockets are always blocking, so WouldBlock only comes from an
                // expired SO_RCVTIMEO/SO_SNDTIMEO, which Unix reports as EAGAIN.
                K::TimedOut | K::WouldBlock => unit($tag::TimedOut),
                K::UnexpectedEof => unit($tag::UnexpectedEof),
                K::Unsupported => unit($tag::Unsupported),
                _ => other(err.to_string()),
            },
        }
    }};
}

/// Builds a Roc `Try(ok, IOErr)` result from a Rust `Result`.
macro_rules! roc_result {
    (
        $result:ident, $payload:ident, $tag:ident,
        $err_ty:ident, $err_payload:ident, $err_tag:ident,
        $value:expr, |$ok:ident| $ok_value:expr
    ) => {
        match $value {
            Ok($ok) => $result {
                payload: $payload { ok: $ok_value },
                tag: $tag::Ok,
            },
            Err(err) => $result {
                payload: $payload {
                    err: ManuallyDrop::new(io_err!($err_ty, $err_payload, $err_tag, err)),
                },
                tag: $tag::Err,
            },
        }
    };
}

/// Result of a hosted function that returns a socket handle.
macro_rules! handle_result {
    ($result:ident, $payload:ident, $tag:ident, $err_ty:ident, $err_payload:ident, $err_tag:ident, $value:expr) => {
        roc_result!($result, $payload, $tag, $err_ty, $err_payload, $err_tag, $value, |handle| {
            ManuallyDrop::new(handle)
        })
    };
}

fn addr_result(value: Result<String, NetErr>) -> HostTcpListenerLocalAddrResult {
    roc_result!(
        HostTcpListenerLocalAddrResult,
        HostTcpListenerLocalAddrResultPayload,
        HostTcpListenerLocalAddrResultTag,
        IOErr,
        IOErrPayload,
        IOErrTag,
        value,
        |addr| ManuallyDrop::new(RocStr::from_str(&addr, roc_host()))
    )
}

fn unit_result(value: Result<(), NetErr>) -> HostTcpSetNodelayResult {
    roc_result!(
        HostTcpSetNodelayResult,
        HostTcpSetNodelayResultPayload,
        HostTcpSetNodelayResultTag,
        IOErr,
        IOErrPayload,
        IOErrTag,
        value,
        |_unit| []
    )
}

/// Release the Roc reference a hosted function received for a socket handle.
/// If it was the last one, this closes the socket (via `roc_dealloc`).
fn release_handle(handle: *mut u64) {
    unsafe {
        decref_box_with(
            handle as RocBox,
            core::mem::align_of::<u64>(),
            false,
            None,
            roc_host(),
        )
    };
}

/// Run `f` on the stream behind `handle`, then release the handle.
fn with_stream<T>(handle: *mut u64, f: impl FnOnce(&TcpStream) -> Result<T, NetErr>) -> Result<T, NetErr> {
    let result = unsafe { sockets::stream(handle) }
        .map_err(NetErr::Other)
        .and_then(f);
    release_handle(handle);
    result
}

fn with_listener<T>(
    handle: *mut u64,
    f: impl FnOnce(&TcpListener) -> Result<T, NetErr>,
) -> Result<T, NetErr> {
    let result = unsafe { sockets::listener(handle) }
        .map_err(NetErr::Other)
        .and_then(f);
    release_handle(handle);
    result
}

fn insert(socket: Socket) -> Result<*mut u64, NetErr> {
    sockets::insert(socket).map_err(|_| NetErr::TooManySockets)
}

/// Hosted function: Host.tcp_listen!
#[no_mangle]
pub extern "C" fn roc_tcp_listen(address: RocStr) -> HostTcpListenResult {
    let result = TcpListener::bind(address.as_str())
        .map_err(NetErr::from)
        .and_then(|listener| insert(Socket::TcpListener(listener)));
    unsafe { address.decref(roc_host()) };
    handle_result!(
        HostTcpListenResult,
        HostTcpListenResultPayload,
        HostTcpListenResultTag,
        IOErr,
        IOErrPayload,
        IOErrTag,
        result
    )
}

/// Hosted function: Host.tcp_accept!
#[no_mangle]
pub extern "C" fn roc_tcp_accept(listener: *mut u64) -> HostTcpAcceptResult {
    let result = with_listener(listener, |listener| {
        let (stream, _peer) = listener.accept()?;
        insert(Socket::TcpStream(stream))
    });
    handle_result!(
        HostTcpAcceptResult,
        HostTcpAcceptResultPayload,
        HostTcpAcceptResultTag,
        HostIOErr,
        HostIOErrPayload,
        HostIOErrTag,
        result
    )
}

/// Hosted function: Host.tcp_listener_local_addr!
#[no_mangle]
pub extern "C" fn roc_tcp_listener_local_addr(listener: *mut u64) -> HostTcpListenerLocalAddrResult {
    addr_result(with_listener(listener, |listener| Ok(listener.local_addr()?.to_string())))
}

/// Try each address `address` resolves to, like `TcpStream::connect`, but with
/// a timeout per attempt. A timeout of 0 means none.
fn connect(address: &str, timeout_ms: u64) -> Result<TcpStream, NetErr> {
    if timeout_ms == 0 {
        return Ok(TcpStream::connect(address)?);
    }
    let timeout = Duration::from_millis(timeout_ms);
    let mut last_err = None;
    for addr in address.to_socket_addrs()? {
        match TcpStream::connect_timeout(&addr, timeout) {
            Ok(stream) => return Ok(stream),
            Err(err) => last_err = Some(err),
        }
    }
    Err(match last_err {
        Some(err) => NetErr::Io(err),
        None => NetErr::Io(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{address} did not resolve to any address"),
        )),
    })
}

/// Hosted function: Host.tcp_connect!
#[no_mangle]
pub extern "C" fn roc_tcp_connect(address: RocStr, timeout_ms: u64) -> HostTcpConnectResult {
    let result = connect(address.as_str(), timeout_ms).and_then(|stream| insert(Socket::TcpStream(stream)));
    unsafe { address.decref(roc_host()) };
    handle_result!(
        HostTcpAcceptResult,
        HostTcpAcceptResultPayload,
        HostTcpAcceptResultTag,
        HostIOErr,
        HostIOErrPayload,
        HostIOErrTag,
        result
    )
}

/// Hosted function: Host.tcp_read!
#[no_mangle]
pub extern "C" fn roc_tcp_read(stream: *mut u64, max: u64) -> HostTcpReadResult {
    let result = with_stream(stream, |mut stream| {
        let mut buf = vec![0u8; max.min(MAX_READ_BYTES) as usize];
        let len = stream.read(&mut buf)?;
        Ok(unsafe { RocListWith::<u8, false>::from_slice(&buf[..len], roc_host()) })
    });
    roc_result!(
        HostTcpReadResult,
        HostTcpReadResultPayload,
        HostTcpReadResultTag,
        IOErr,
        IOErrPayload,
        IOErrTag,
        result,
        |bytes| ManuallyDrop::new(bytes)
    )
}

/// Hosted function: Host.tcp_write!
#[no_mangle]
pub extern "C" fn roc_tcp_write(stream: *mut u64, bytes: RocListWith<u8, false>) -> HostTcpWriteResult {
    let result = with_stream(stream, |mut stream| Ok(stream.write_all(bytes.as_slice())?));
    unsafe { bytes.decref(roc_host()) };
    unit_result(result)
}

/// Hosted function: Host.tcp_shutdown!
#[no_mangle]
pub extern "C" fn roc_tcp_shutdown(stream: *mut u64, how: u8) -> HostTcpShutdownResult {
    let how = match how {
        0 => Shutdown::Read,
        1 => Shutdown::Write,
        _ => Shutdown::Both,
    };
    unit_result(with_stream(stream, |stream| Ok(stream.shutdown(how)?)))
}

/// Hosted function: Host.tcp_set_timeout!
#[no_mangle]
pub extern "C" fn roc_tcp_set_timeout(stream: *mut u64, which: u8, timeout_ms: u64) -> HostTcpSetTimeoutResult {
    let timeout = (timeout_ms > 0).then(|| Duration::from_millis(timeout_ms));
    unit_result(with_stream(stream, |stream| {
        Ok(match which {
            0 => stream.set_read_timeout(timeout)?,
            _ => stream.set_write_timeout(timeout)?,
        })
    }))
}

/// Hosted function: Host.tcp_set_nodelay!
#[no_mangle]
pub extern "C" fn roc_tcp_set_nodelay(stream: *mut u64, enabled: bool) -> HostTcpSetNodelayResult {
    unit_result(with_stream(stream, |stream| Ok(stream.set_nodelay(enabled)?)))
}

/// Hosted function: Host.tcp_local_addr!
#[no_mangle]
pub extern "C" fn roc_tcp_local_addr(stream: *mut u64) -> HostTcpLocalAddrResult {
    addr_result(with_stream(stream, |stream| Ok(stream.local_addr()?.to_string())))
}

/// Hosted function: Host.tcp_peer_addr!
#[no_mangle]
pub extern "C" fn roc_tcp_peer_addr(stream: *mut u64) -> HostTcpPeerAddrResult {
    addr_result(with_stream(stream, |stream| Ok(stream.peer_addr()?.to_string())))
}
