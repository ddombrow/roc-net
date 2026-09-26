//! Hosted socket functions (TCP, Unix, UDP) and the mapping from Rust I/O
//! errors to Roc's `IOErr`.

use std::io::{self, Read, Write};
use std::mem::ManuallyDrop;
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

use crate::roc_host;
use crate::roc_platform_abi::{
    decref_box_with, AnonStruct4f4f23a245dfe10a as RocRecvFrom, HostDnsResolveResult,
    HostDnsResolveResultPayload, HostDnsResolveResultTag, HostIOErr, HostIOErrPayload,
    HostIOErrTag, HostSocketAcceptResult, HostSocketAcceptResultPayload,
    HostSocketAcceptResultTag, HostSocketLocalAddrResult, HostSocketLocalAddrResultPayload,
    HostSocketLocalAddrResultTag, HostSocketReadResult, HostSocketReadResultPayload,
    HostSocketReadResultTag, HostSocketSetTimeoutResult, HostSocketSetTimeoutResultPayload,
    HostSocketSetTimeoutResultTag, HostUdpRecvFromResult, HostUdpRecvFromResultPayload,
    HostUdpRecvFromResultTag, IOErr, IOErrPayload, IOErrTag, RocBox, RocList, RocListWith, RocStr,
};
use crate::sockets::{self, OwnedUnixListener, Socket};

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

/// Conversion into whichever copy of Roc's `IOErr` a result uses. The glue
/// emits identical copies (`IOErr`, `HostIOErr`) and which result gets which
/// can change when it's regenerated, so results name neither: the payload's
/// field type picks the implementation.
trait FromNetErr {
    fn from_net_err(err: NetErr) -> Self;
}

macro_rules! impl_from_net_err {
    ($ty:ident, $payload:ident, $tag:ident) => {
        impl FromNetErr for $ty {
            fn from_net_err(err: NetErr) -> Self {
                io_err!($ty, $payload, $tag, err)
            }
        }
    };
}

impl_from_net_err!(IOErr, IOErrPayload, IOErrTag);
impl_from_net_err!(HostIOErr, HostIOErrPayload, HostIOErrTag);

/// Builds a Roc `Try(ok, IOErr)` result from a Rust `Result`.
macro_rules! roc_result {
    ($result:ident, $payload:ident, $tag:ident, $value:expr, |$ok:ident| $ok_value:expr) => {
        match $value {
            Ok($ok) => $result {
                payload: $payload { ok: $ok_value },
                tag: $tag::Ok,
            },
            Err(err) => $result {
                payload: $payload {
                    err: ManuallyDrop::new(FromNetErr::from_net_err(err)),
                },
                tag: $tag::Err,
            },
        }
    };
}

type NetResult<T> = Result<T, NetErr>;

fn handle_result(value: NetResult<*mut u64>) -> HostSocketAcceptResult {
    roc_result!(
        HostSocketAcceptResult,
        HostSocketAcceptResultPayload,
        HostSocketAcceptResultTag,
        value,
        |handle| ManuallyDrop::new(handle)
    )
}

fn str_result(value: NetResult<String>) -> HostSocketLocalAddrResult {
    roc_result!(
        HostSocketLocalAddrResult,
        HostSocketLocalAddrResultPayload,
        HostSocketLocalAddrResultTag,
        value,
        |text| ManuallyDrop::new(RocStr::from_str(&text, roc_host()))
    )
}

fn bytes_result(value: NetResult<RocListWith<u8, false>>) -> HostSocketReadResult {
    roc_result!(
        HostSocketReadResult,
        HostSocketReadResultPayload,
        HostSocketReadResultTag,
        value,
        |bytes| ManuallyDrop::new(bytes)
    )
}

fn unit_result(value: NetResult<()>) -> HostSocketSetTimeoutResult {
    roc_result!(
        HostSocketSetTimeoutResult,
        HostSocketSetTimeoutResultPayload,
        HostSocketSetTimeoutResultTag,
        value,
        |_unit| []
    )
}

fn roc_bytes(bytes: &[u8]) -> RocListWith<u8, false> {
    unsafe { RocListWith::<u8, false>::from_slice(bytes, roc_host()) }
}

/// An operation was applied to the wrong kind of socket. The public Roc types
/// rule this out, so it only happens if the platform itself has a bug.
fn wrong_kind(operation: &str) -> NetErr {
    NetErr::Io(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{operation} is not supported on this kind of socket"),
    ))
}

/// Release the Roc reference a hosted function received for a socket handle.
/// If it was the last one, this closes the socket (via `roc_dealloc`).
fn release_handle(handle: *mut u64) {
    unsafe {
        decref_box_with(handle as RocBox, core::mem::align_of::<u64>(), false, None, roc_host())
    };
}

/// Run `f` on the socket behind `handle`, then release the handle.
fn with_socket<T>(handle: *mut u64, f: impl FnOnce(&Socket) -> NetResult<T>) -> NetResult<T> {
    let result = match unsafe { sockets::get(handle) } {
        Some(socket) => f(socket),
        None => Err(NetErr::Other("invalid socket handle".into())),
    };
    release_handle(handle);
    result
}

/// Create a socket with `open` and hand it to Roc, failing with
/// `TooManySockets` (before opening anything) if the socket limit is reached.
fn open_socket(open: impl FnOnce() -> NetResult<Socket>) -> NetResult<*mut u64> {
    let slot = sockets::try_reserve().map_err(|_| NetErr::TooManySockets)?;
    Ok(slot.insert(open()?))
}

/// Run `f` with a Roc string argument, then release it.
fn with_str<T>(text: RocStr, f: impl FnOnce(&str) -> T) -> T {
    let result = f(text.as_str());
    unsafe { text.decref(roc_host()) };
    result
}

// --- Creating sockets ---

/// Try each address `address` resolves to, like `TcpStream::connect`, but with
/// a timeout per attempt. A timeout of 0 means none.
fn tcp_connect(address: &str, timeout_ms: u64) -> NetResult<TcpStream> {
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
    Err(NetErr::Io(last_err.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("{address} did not resolve to any address"))
    })))
}

/// Bind a Unix listener, replacing a socket file left behind by a program
/// that exited without cleaning up. A file that some process is still
/// listening on is left alone, and binding fails with `AddrInUse`.
fn unix_listen(path: &str) -> NetResult<OwnedUnixListener> {
    let listener = match UnixListener::bind(path) {
        Ok(listener) => listener,
        Err(err) if err.kind() == io::ErrorKind::AddrInUse && is_stale_socket(path) => {
            std::fs::remove_file(path)?;
            UnixListener::bind(path)?
        }
        Err(err) => return Err(err.into()),
    };
    Ok(OwnedUnixListener { listener, path: path.into() })
}

fn is_stale_socket(path: &str) -> bool {
    let is_socket = std::fs::symlink_metadata(path)
        .map(|meta| meta.file_type().is_socket())
        .unwrap_or(false);
    is_socket
        && matches!(UnixStream::connect(path), Err(err) if err.kind() == io::ErrorKind::ConnectionRefused)
}

/// Hosted function: Host.tcp_listen!
#[no_mangle]
pub extern "C" fn roc_tcp_listen(address: RocStr) -> HostSocketAcceptResult {
    handle_result(with_str(address, |address| {
        open_socket(|| Ok(Socket::TcpListener(TcpListener::bind(address)?)))
    }))
}

/// Hosted function: Host.tcp_connect!
#[no_mangle]
pub extern "C" fn roc_tcp_connect(address: RocStr, timeout_ms: u64) -> HostSocketAcceptResult {
    handle_result(with_str(address, |address| {
        open_socket(|| Ok(Socket::TcpStream(tcp_connect(address, timeout_ms)?)))
    }))
}

/// Hosted function: Host.unix_listen!
#[no_mangle]
pub extern "C" fn roc_unix_listen(path: RocStr) -> HostSocketAcceptResult {
    handle_result(with_str(path, |path| open_socket(|| Ok(Socket::UnixListener(unix_listen(path)?)))))
}

/// Hosted function: Host.unix_connect!
#[no_mangle]
pub extern "C" fn roc_unix_connect(path: RocStr) -> HostSocketAcceptResult {
    handle_result(with_str(path, |path| {
        open_socket(|| Ok(Socket::UnixStream(UnixStream::connect(path)?)))
    }))
}

/// Hosted function: Host.udp_bind!
#[no_mangle]
pub extern "C" fn roc_udp_bind(address: RocStr) -> HostSocketAcceptResult {
    handle_result(with_str(address, |address| open_socket(|| Ok(Socket::Udp(UdpSocket::bind(address)?)))))
}

// --- Accepting ---

/// Warn once per process that the file-descriptor limit is throttling accepts.
fn warn_out_of_fds() {
    use std::sync::atomic::{AtomicBool, Ordering};
    static WARNED: AtomicBool = AtomicBool::new(false);
    if !WARNED.swap(true, Ordering::Relaxed) {
        eprintln!(
            "roc-net: out of file descriptors; waiting before accepting more connections \
             (raise the limit with `ulimit -n`)"
        );
    }
}

/// Call `accept` until it succeeds or fails for a real reason. Errors that
/// only mean "try again" are retried here rather than returned, so a
/// server's accept loop doesn't end over them.
fn accept_retrying<T>(mut accept: impl FnMut() -> io::Result<T>) -> io::Result<T> {
    // EMFILE / ENFILE: this process / the system is out of file descriptors.
    const EMFILE: i32 = 24;
    const ENFILE: i32 = 23;
    loop {
        match accept() {
            Ok(accepted) => return Ok(accepted),
            Err(err)
                if matches!(
                    err.kind(),
                    io::ErrorKind::ConnectionAborted | io::ErrorKind::Interrupted
                ) => {}
            Err(err) if matches!(err.raw_os_error(), Some(EMFILE | ENFILE)) => {
                warn_out_of_fds();
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(err) => return Err(err),
        }
    }
}

/// Hosted function: Host.socket_accept!
#[no_mangle]
pub extern "C" fn roc_socket_accept(listener: *mut u64) -> HostSocketAcceptResult {
    handle_result(with_socket(listener, |listener| {
        // Wait for a free socket slot before accepting, so at the limit new
        // clients wait in the kernel's accept queue instead of being accepted
        // and immediately dropped.
        let slot = sockets::reserve();
        let accepted = match listener {
            Socket::TcpListener(l) => Socket::TcpStream(accept_retrying(|| l.accept())?.0),
            Socket::UnixListener(l) => Socket::UnixStream(accept_retrying(|| l.listener.accept())?.0),
            Socket::TlsListener(l) => {
                let tcp = accept_retrying(|| l.listener.accept())?.0;
                Socket::Tls(crate::tls::server(tcp, l.config.clone())?)
            }
            _ => return Err(wrong_kind("accept")),
        };
        Ok(slot.insert(accepted))
    }))
}

// --- Streams (and connected UDP) ---

/// Hosted function: Host.socket_read!
#[no_mangle]
pub extern "C" fn roc_socket_read(socket: *mut u64, max: u64) -> HostSocketReadResult {
    bytes_result(with_socket(socket, |socket| {
        let mut buf = vec![0u8; max.min(MAX_READ_BYTES) as usize];
        let len = match socket {
            Socket::TcpStream(s) => (&mut &*s).read(&mut buf)?,
            Socket::UnixStream(s) => (&mut &*s).read(&mut buf)?,
            Socket::Udp(s) => s.recv(&mut buf)?,
            Socket::Tls(s) => s.read(&mut buf)?,
            _ => return Err(wrong_kind("read")),
        };
        Ok(roc_bytes(&buf[..len]))
    }))
}

/// Hosted function: Host.socket_write!
#[no_mangle]
pub extern "C" fn roc_socket_write(socket: *mut u64, bytes: RocListWith<u8, false>) -> HostSocketSetTimeoutResult {
    let result = with_socket(socket, |socket| {
        let data = bytes.as_slice();
        match socket {
            Socket::TcpStream(s) => (&mut &*s).write_all(data)?,
            Socket::UnixStream(s) => (&mut &*s).write_all(data)?,
            Socket::Udp(s) => check_datagram_sent(s.send(data)?, data.len())?,
            Socket::Tls(s) => s.write_all(data)?,
            _ => return Err(wrong_kind("write")),
        }
        Ok(())
    });
    unsafe { bytes.decref(roc_host()) };
    unit_result(result)
}

/// A datagram is sent whole or not at all; a short count means the OS
/// truncated it.
fn check_datagram_sent(sent: usize, len: usize) -> NetResult<()> {
    if sent == len {
        Ok(())
    } else {
        Err(NetErr::Other(format!("sent only {sent} of {len} bytes of the datagram")))
    }
}

/// Hosted function: Host.socket_shutdown!
#[no_mangle]
pub extern "C" fn roc_socket_shutdown(socket: *mut u64, how: u8) -> HostSocketSetTimeoutResult {
    let how = match how {
        0 => Shutdown::Read,
        1 => Shutdown::Write,
        _ => Shutdown::Both,
    };
    unit_result(with_socket(socket, |socket| {
        match socket {
            Socket::TcpStream(s) => s.shutdown(how)?,
            Socket::UnixStream(s) => s.shutdown(how)?,
            Socket::Tls(s) => s.shutdown(how)?,
            _ => return Err(wrong_kind("shutdown")),
        }
        Ok(())
    }))
}

/// Hosted function: Host.socket_set_timeout!
#[no_mangle]
pub extern "C" fn roc_socket_set_timeout(socket: *mut u64, which: u8, timeout_ms: u64) -> HostSocketSetTimeoutResult {
    let timeout = (timeout_ms > 0).then(|| Duration::from_millis(timeout_ms));
    let read = which == 0;
    unit_result(with_socket(socket, |socket| {
        match (socket, read) {
            (Socket::TcpStream(s), true) => s.set_read_timeout(timeout)?,
            (Socket::TcpStream(s), false) => s.set_write_timeout(timeout)?,
            (Socket::UnixStream(s), true) => s.set_read_timeout(timeout)?,
            (Socket::UnixStream(s), false) => s.set_write_timeout(timeout)?,
            (Socket::Udp(s), true) => s.set_read_timeout(timeout)?,
            (Socket::Udp(s), false) => s.set_write_timeout(timeout)?,
            (Socket::Tls(s), true) => s.tcp().set_read_timeout(timeout)?,
            (Socket::Tls(s), false) => s.tcp().set_write_timeout(timeout)?,
            _ => return Err(wrong_kind("setting a timeout")),
        }
        Ok(())
    }))
}

fn unix_path(addr: std::os::unix::net::SocketAddr) -> String {
    addr.as_pathname()
        .map(|path| path.display().to_string())
        .unwrap_or_default()
}

/// Hosted function: Host.socket_local_addr!
#[no_mangle]
pub extern "C" fn roc_socket_local_addr(socket: *mut u64) -> HostSocketLocalAddrResult {
    str_result(with_socket(socket, |socket| {
        Ok(match socket {
            Socket::TcpListener(s) => s.local_addr()?.to_string(),
            Socket::TcpStream(s) => s.local_addr()?.to_string(),
            Socket::Udp(s) => s.local_addr()?.to_string(),
            Socket::UnixListener(s) => unix_path(s.listener.local_addr()?),
            Socket::UnixStream(s) => unix_path(s.local_addr()?),
            Socket::TlsListener(s) => s.listener.local_addr()?.to_string(),
            Socket::Tls(s) => s.tcp().local_addr()?.to_string(),
        })
    }))
}

/// Hosted function: Host.socket_peer_addr!
#[no_mangle]
pub extern "C" fn roc_socket_peer_addr(socket: *mut u64) -> HostSocketLocalAddrResult {
    str_result(with_socket(socket, |socket| {
        Ok(match socket {
            Socket::TcpStream(s) => s.peer_addr()?.to_string(),
            Socket::Udp(s) => s.peer_addr()?.to_string(),
            Socket::UnixStream(s) => unix_path(s.peer_addr()?),
            Socket::Tls(s) => s.tcp().peer_addr()?.to_string(),
            _ => return Err(wrong_kind("peer_addr")),
        })
    }))
}

/// Hosted function: Host.tcp_set_nodelay!
#[no_mangle]
pub extern "C" fn roc_tcp_set_nodelay(socket: *mut u64, enabled: bool) -> HostSocketSetTimeoutResult {
    unit_result(with_socket(socket, |socket| match socket {
        Socket::TcpStream(s) => Ok(s.set_nodelay(enabled)?),
        Socket::Tls(s) => Ok(s.tcp().set_nodelay(enabled)?),
        _ => Err(wrong_kind("set_nodelay")),
    }))
}

// --- UDP ---

fn with_udp<T>(handle: *mut u64, f: impl FnOnce(&UdpSocket) -> NetResult<T>) -> NetResult<T> {
    with_socket(handle, |socket| match socket {
        Socket::Udp(s) => f(s),
        _ => Err(wrong_kind("this UDP operation")),
    })
}

/// Hosted function: Host.udp_connect!
#[no_mangle]
pub extern "C" fn roc_udp_connect(socket: *mut u64, address: RocStr) -> HostSocketSetTimeoutResult {
    unit_result(with_str(address, |address| with_udp(socket, |s| Ok(s.connect(address)?))))
}

/// Hosted function: Host.udp_send_to!
#[no_mangle]
pub extern "C" fn roc_udp_send_to(
    socket: *mut u64,
    bytes: RocListWith<u8, false>,
    address: RocStr,
) -> HostSocketSetTimeoutResult {
    let result = with_str(address, |address| {
        with_udp(socket, |s| {
            let data = bytes.as_slice();
            check_datagram_sent(s.send_to(data, address)?, data.len())
        })
    });
    unsafe { bytes.decref(roc_host()) };
    unit_result(result)
}

/// Hosted function: Host.udp_recv_from!
#[no_mangle]
pub extern "C" fn roc_udp_recv_from(socket: *mut u64, max: u64) -> HostUdpRecvFromResult {
    let result = with_udp(socket, |s| {
        let mut buf = vec![0u8; max.min(MAX_READ_BYTES) as usize];
        let (len, from): (usize, SocketAddr) = s.recv_from(&mut buf)?;
        Ok(RocRecvFrom {
            bytes: roc_bytes(&buf[..len]),
            from: RocStr::from_str(&from.to_string(), roc_host()),
        })
    });
    roc_result!(
        HostUdpRecvFromResult,
        HostUdpRecvFromResultPayload,
        HostUdpRecvFromResultTag,
        result,
        |received| ManuallyDrop::new(received)
    )
}

/// Hosted function: Host.udp_set_broadcast!
#[no_mangle]
pub extern "C" fn roc_udp_set_broadcast(socket: *mut u64, enabled: bool) -> HostSocketSetTimeoutResult {
    unit_result(with_udp(socket, |s| Ok(s.set_broadcast(enabled)?)))
}

fn multicast_group(group: &str) -> NetResult<IpAddr> {
    group.parse().map_err(|_| {
        NetErr::Io(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{group:?} is not an IP address"),
        ))
    })
}

/// Hosted function: Host.udp_join_multicast!
#[no_mangle]
pub extern "C" fn roc_udp_join_multicast(socket: *mut u64, group: RocStr) -> HostSocketSetTimeoutResult {
    unit_result(with_str(group, |group| {
        with_udp(socket, |s| {
            match multicast_group(group)? {
                IpAddr::V4(g) => s.join_multicast_v4(&g, &Ipv4Addr::UNSPECIFIED)?,
                IpAddr::V6(g) => s.join_multicast_v6(&g, 0)?,
            }
            Ok(())
        })
    }))
}

/// Hosted function: Host.udp_leave_multicast!
#[no_mangle]
pub extern "C" fn roc_udp_leave_multicast(socket: *mut u64, group: RocStr) -> HostSocketSetTimeoutResult {
    unit_result(with_str(group, |group| {
        with_udp(socket, |s| {
            match multicast_group(group)? {
                IpAddr::V4(g) => s.leave_multicast_v4(&g, &Ipv4Addr::UNSPECIFIED)?,
                IpAddr::V6(g) => s.leave_multicast_v6(&g, 0)?,
            }
            Ok(())
        })
    }))
}

// --- Name resolution ---

/// Resolve `name` with the OS resolver, keeping each address once, in the
/// order the resolver returned them.
fn resolve(name: &str) -> NetResult<Vec<String>> {
    let mut addresses: Vec<String> = Vec::new();
    for addr in (name, 0).to_socket_addrs()? {
        let ip = addr.ip().to_string();
        if !addresses.contains(&ip) {
            addresses.push(ip);
        }
    }
    if addresses.is_empty() {
        return Err(NetErr::Io(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{name} has no addresses"),
        )));
    }
    Ok(addresses)
}

fn roc_str_list(items: &[String]) -> RocList<RocStr> {
    let list = unsafe { RocList::<RocStr>::allocate(items.len(), roc_host()) };
    for (i, item) in items.iter().enumerate() {
        unsafe { list.elements.add(i).write(RocStr::from_str(item, roc_host())) };
    }
    list
}

/// Hosted function: Host.dns_resolve!
#[no_mangle]
pub extern "C" fn roc_dns_resolve(name: RocStr) -> HostDnsResolveResult {
    let result = with_str(name, resolve);
    roc_result!(
        HostDnsResolveResult,
        HostDnsResolveResultPayload,
        HostDnsResolveResultTag,
        result,
        |addresses| ManuallyDrop::new(roc_str_list(&addresses))
    )
}

// --- TLS ---

/// Hosted function: Host.tls_connect!
#[no_mangle]
pub extern "C" fn roc_tls_connect(
    address: RocStr,
    server_name: RocStr,
    ca_file: RocStr,
    timeout_ms: u64,
) -> HostSocketAcceptResult {
    let result = with_str(address, |address| {
        with_str(server_name, |server_name| {
            with_str(ca_file, |ca_file| {
                open_socket(|| {
                    let tcp = tcp_connect(address, timeout_ms)?;
                    let name = if server_name.is_empty() { crate::tls::host_of(address) } else { server_name };
                    let timeout = (timeout_ms > 0).then(|| Duration::from_millis(timeout_ms));
                    Ok(Socket::Tls(crate::tls::client(tcp, name, ca_file, timeout)?))
                })
            })
        })
    });
    handle_result(result)
}

/// Hosted function: Host.tls_listen!
#[no_mangle]
pub extern "C" fn roc_tls_listen(address: RocStr, cert_file: RocStr, key_file: RocStr) -> HostSocketAcceptResult {
    let result = with_str(address, |address| {
        with_str(cert_file, |cert_file| {
            with_str(key_file, |key_file| {
                open_socket(|| {
                    let config = crate::tls::server_config(cert_file, key_file)?;
                    let listener = TcpListener::bind(address)?;
                    Ok(Socket::TlsListener(crate::sockets::TlsListener { listener, config }))
                })
            })
        })
    });
    handle_result(result)
}

/// The TCP connection behind a plain stream handle, for upgrading to TLS.
/// The upgraded stream gets its own handle on the same connection; the plain
/// handle must not be used afterwards, or it would read or write raw bytes in
/// the middle of the TLS session.
fn plain_tcp(socket: &Socket) -> NetResult<TcpStream> {
    match socket {
        Socket::TcpStream(s) => Ok(s.try_clone()?),
        _ => Err(wrong_kind("upgrading to TLS")),
    }
}

/// Hosted function: Host.tls_wrap_client!
#[no_mangle]
pub extern "C" fn roc_tls_wrap_client(socket: *mut u64, server_name: RocStr, ca_file: RocStr) -> HostSocketAcceptResult {
    let result = with_str(server_name, |server_name| {
        with_str(ca_file, |ca_file| {
            with_socket(socket, |socket| {
                let tcp = plain_tcp(socket)?;
                open_socket(|| Ok(Socket::Tls(crate::tls::client(tcp, server_name, ca_file, None)?)))
            })
        })
    });
    handle_result(result)
}

/// Hosted function: Host.tls_wrap_server!
#[no_mangle]
pub extern "C" fn roc_tls_wrap_server(socket: *mut u64, cert_file: RocStr, key_file: RocStr) -> HostSocketAcceptResult {
    let result = with_str(cert_file, |cert_file| {
        with_str(key_file, |key_file| {
            with_socket(socket, |socket| {
                let tcp = plain_tcp(socket)?;
                let config = crate::tls::server_config(cert_file, key_file)?;
                open_socket(|| Ok(Socket::Tls(crate::tls::server(tcp, config)?)))
            })
        })
    });
    handle_result(result)
}

/// Hosted function: Host.tls_ignore_unexpected_eof!
#[no_mangle]
pub extern "C" fn roc_tls_ignore_unexpected_eof(socket: *mut u64, ignore: bool) -> HostSocketSetTimeoutResult {
    unit_result(with_socket(socket, |socket| match socket {
        Socket::Tls(s) => {
            s.set_ignore_unexpected_eof(ignore);
            Ok(())
        }
        _ => Err(wrong_kind("ignore_unexpected_eof")),
    }))
}
