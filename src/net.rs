//! Hosted socket functions (TCP, Unix, UDP) and the mapping from Rust I/O
//! errors to Roc's `IOErr`.

use std::io::{self, Read, Write};
use std::mem::ManuallyDrop;
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream, UdpSocket};
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
use crate::sockets::{self, deadline_after, with_scratch, Conn, OwnedUnixListener, ServerTimeouts, Socket};

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
                // Waits that time out report TimedOut; WouldBlock never reaches
                // Roc (operations retry after waiting), but would mean the same.
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

/// Connect to `address` ("host:port"), trying each address the name resolves
/// to in turn, like `TcpStream::connect`, all before `deadline`: the name
/// lookup and every connection attempt share it. Each attempt gets an equal
/// share of the time left, so an unreachable first address (say, IPv6 on a
/// network without it) can't use up the whole budget before the others get a
/// turn. Without a deadline, nothing is bounded but the OS's own limits.
fn tcp_connect(address: &str, deadline: Option<std::time::Instant>) -> NetResult<Conn<TcpStream>> {
    let addrs = crate::resolve::socket_addrs(address, deadline)?;
    let mut last_err = None;
    for (i, addr) in addrs.iter().enumerate() {
        let attempt_deadline = match deadline {
            None => None,
            Some(deadline) => {
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                if left.is_zero() {
                    break;
                }
                let share = left / (addrs.len() - i) as u32;
                std::time::Instant::now().checked_add(share.max(Duration::from_millis(1)))
            }
        };
        match connect_one(*addr, attempt_deadline) {
            Ok(stream) => return Ok(stream),
            Err(err) => last_err = Some(err),
        }
    }
    Err(NetErr::Io(last_err.unwrap_or_else(|| {
        if addrs.is_empty() {
            io::Error::new(io::ErrorKind::NotFound, format!("{address} did not resolve to any address"))
        } else {
            io::Error::new(io::ErrorKind::TimedOut, format!("connecting to {address} timed out"))
        }
    })))
}

/// A non-blocking connect: start it, then wait until the socket is writable,
/// which is when the connection is made or has failed.
fn connect_one(addr: SocketAddr, deadline: Option<std::time::Instant>) -> io::Result<Conn<TcpStream>> {
    let stream = Conn::new(TcpStream::from(mio::net::TcpStream::connect(addr)?));
    loop {
        stream.wait_writable(deadline)?;
        if let Some(err) = stream.io.take_error()? {
            return Err(err);
        }
        match stream.io.peer_addr() {
            Ok(_) => return Ok(stream),
            // Not connected yet: that wake-up was early.
            Err(err) if err.kind() == io::ErrorKind::NotConnected => {}
            Err(err) => return Err(err),
        }
    }
}

/// Bind a TCP listener, resolving `address` off the worker thread.
fn tcp_bind(address: &str) -> NetResult<Conn<TcpListener>> {
    let addrs = crate::resolve::socket_addrs(address, None)?;
    let listener = TcpListener::bind(&addrs[..])?;
    listener.set_nonblocking(true)?;
    Ok(Conn::new(listener))
}

/// Connect to a Unix socket without blocking the worker, giving up with
/// `TimedOut` at `deadline`. A local connect finishes (or fails) at once,
/// except when the listener's queue is full: then Linux reports
/// `WouldBlock`, with no event to say when there's room, so it retries after
/// a pause that grows to 50 ms. (macOS refuses the connection instead.)
fn unix_connect(path: &str, deadline: Option<std::time::Instant>) -> io::Result<Conn<UnixStream>> {
    let mut pause = Duration::from_millis(1);
    loop {
        match mio::net::UnixStream::connect(path) {
            Ok(stream) => {
                let stream = Conn::new(UnixStream::from(stream));
                // Connected already, normally; if still in progress, wait.
                while let Err(err) = stream.io.peer_addr() {
                    if err.kind() != io::ErrorKind::NotConnected {
                        return Err(err);
                    }
                    stream.wait_writable(deadline)?;
                    if let Some(err) = stream.io.take_error()? {
                        return Err(err);
                    }
                }
                return Ok(stream);
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                let now = std::time::Instant::now();
                let pause_until = now + pause;
                if deadline.is_some_and(|deadline| deadline <= now) {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, format!("connecting to {path} timed out")));
                }
                let wake = deadline.map_or(pause_until, |deadline| deadline.min(pause_until));
                crate::sched::sleep(wake.saturating_duration_since(now));
                pause = (pause * 2).min(Duration::from_millis(50));
            }
            Err(err) => return Err(err),
        }
    }
}

/// Bind a Unix listener, replacing a socket file left behind by a program
/// that exited without cleaning up. A file that some process is still
/// listening on is left alone, and binding fails with `AddrInUse`.
fn unix_listen(path: &str, timeouts: ServerTimeouts) -> NetResult<OwnedUnixListener> {
    let listener = match UnixListener::bind(path) {
        Ok(listener) => listener,
        Err(err) if err.kind() == io::ErrorKind::AddrInUse && is_stale_socket(path) => {
            std::fs::remove_file(path)?;
            UnixListener::bind(path)?
        }
        Err(err) => return Err(err.into()),
    };
    listener.set_nonblocking(true)?;
    Ok(OwnedUnixListener { listener: Conn::new(listener), path: path.into(), timeouts })
}

/// A socket file nobody is listening on: connecting is refused. Checked with
/// a non-blocking connect, so a live listener with a full queue (`WouldBlock`)
/// counts as live without stalling the worker.
fn is_stale_socket(path: &str) -> bool {
    let is_socket = std::fs::symlink_metadata(path)
        .map(|meta| meta.file_type().is_socket())
        .unwrap_or(false);
    is_socket
        && matches!(mio::net::UnixStream::connect(path), Err(err) if err.kind() == io::ErrorKind::ConnectionRefused)
}

/// Hosted function: Host.tcp_listen!
#[no_mangle]
pub extern "C" fn roc_tcp_listen(address: RocStr, idle_ms: u64, write_ms: u64) -> HostSocketAcceptResult {
    let timeouts = ServerTimeouts { idle_ms, write_ms };
    handle_result(with_str(address, |address| open_socket(|| Ok(Socket::TcpListener(tcp_bind(address)?, timeouts)))))
}

/// Hosted function: Host.tcp_connect!
#[no_mangle]
pub extern "C" fn roc_tcp_connect(address: RocStr, timeout_ms: u64) -> HostSocketAcceptResult {
    handle_result(with_str(address, |address| {
        open_socket(|| Ok(Socket::TcpStream(tcp_connect(address, deadline_after(timeout_ms))?)))
    }))
}

/// Hosted function: Host.unix_listen!
#[no_mangle]
pub extern "C" fn roc_unix_listen(path: RocStr, idle_ms: u64, write_ms: u64) -> HostSocketAcceptResult {
    let timeouts = ServerTimeouts { idle_ms, write_ms };
    handle_result(with_str(path, |path| {
        open_socket(|| Ok(Socket::UnixListener(unix_listen(path, timeouts)?)))
    }))
}

/// Hosted function: Host.unix_connect!
#[no_mangle]
pub extern "C" fn roc_unix_connect(path: RocStr, timeout_ms: u64) -> HostSocketAcceptResult {
    handle_result(with_str(path, |path| {
        // Connect first, then claim a socket slot, so a connect that waits
        // for room in the listener's queue doesn't hold a slot meanwhile. At
        // the socket limit the new connection is closed again.
        let stream = unix_connect(path, deadline_after(timeout_ms))?;
        open_socket(|| Ok(Socket::UnixStream(stream)))
    }))
}

/// Hosted function: Host.udp_bind!
#[no_mangle]
pub extern "C" fn roc_udp_bind(address: RocStr) -> HostSocketAcceptResult {
    handle_result(with_str(address, |address| {
        open_socket(|| {
            let addrs = crate::resolve::socket_addrs(address, None)?;
            let socket = UdpSocket::bind(&addrs[..])?;
            socket.set_nonblocking(true)?;
            Ok(Socket::Udp(Conn::new(socket)))
        })
    }))
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

/// Accept a connection, waiting for one to arrive. Errors that only mean
/// "try again" are retried here rather than returned, so a server's accept
/// loop doesn't end over them. The new socket is made non-blocking.
fn accept_retrying<L: std::os::fd::AsRawFd, S>(
    listener: &Conn<L>,
    accept: impl Fn(&L) -> io::Result<S>,
    nonblocking: impl Fn(&S) -> io::Result<()>,
) -> io::Result<Conn<S>>
where
    S: std::os::fd::AsRawFd,
{
    // EMFILE / ENFILE: this process / the system is out of file descriptors.
    const EMFILE: i32 = 24;
    const ENFILE: i32 = 23;
    loop {
        match listener.retry(false, None, &accept) {
            Ok(stream) => {
                nonblocking(&stream)?;
                return Ok(Conn::new(stream));
            }
            Err(err)
                if matches!(
                    err.kind(),
                    io::ErrorKind::ConnectionAborted | io::ErrorKind::Interrupted
                ) => {}
            Err(err) if matches!(err.raw_os_error(), Some(EMFILE | ENFILE)) => {
                warn_out_of_fds();
                crate::sched::sleep(Duration::from_millis(50));
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
        let tcp_accept = |l: &TcpListener| l.accept().map(|(stream, _)| stream);
        let tcp_nonblocking = |s: &TcpStream| s.set_nonblocking(true);
        let accepted = match listener {
            Socket::TcpListener(l, timeouts) => {
                let stream = accept_retrying(l, tcp_accept, tcp_nonblocking)?;
                timeouts.apply(&stream);
                Socket::TcpStream(stream)
            }
            Socket::UnixListener(l) => {
                let stream = accept_retrying(
                    &l.listener,
                    |l: &UnixListener| l.accept().map(|(stream, _)| stream),
                    |s: &UnixStream| s.set_nonblocking(true),
                )?;
                l.timeouts.apply(&stream);
                Socket::UnixStream(stream)
            }
            Socket::TlsListener(l) => {
                let tcp = accept_retrying(&l.listener, tcp_accept, tcp_nonblocking)?;
                l.timeouts.apply(&tcp);
                // The handshake clock starts now, at accept.
                let deadline = deadline_after(l.handshake_timeout_ms);
                Socket::Tls(Box::new(crate::tls::server(tcp, l.config.clone(), deadline)?))
            }
            _ => return Err(wrong_kind("accept")),
        };
        Ok(slot.insert(accepted))
    }))
}

// --- Streams (and connected UDP) ---

/// Read from a stream (or connected UDP socket), waiting until something
/// arrives or the read timeout passes, and hand what arrived to `got`. At
/// most `max` bytes, read into this thread's scratch buffer (see
/// `with_scratch`), which is only borrowed once the socket is ready.
fn read_stream<R>(socket: &Socket, max: u64, what: &str, mut got: impl FnMut(&[u8]) -> R) -> NetResult<R> {
    let max = max.min(MAX_READ_BYTES) as usize;
    Ok(match socket {
        Socket::TcpStream(s) => s.read_with(|s| {
            with_scratch(max, |buf| {
                let len = (&mut &*s).read(buf)?;
                Ok(got(&buf[..len]))
            })
        })?,
        Socket::UnixStream(s) => s.read_with(|s| {
            with_scratch(max, |buf| {
                let len = (&mut &*s).read(buf)?;
                Ok(got(&buf[..len]))
            })
        })?,
        Socket::Udp(s) if what == "read" => s.read_with(|s| {
            with_scratch(max, |buf| {
                let len = s.recv(buf)?;
                Ok(got(&buf[..len]))
            })
        })?,
        Socket::Tls(s) => loop {
            let received = with_scratch(max, |buf| {
                let len = s.try_read(buf)?;
                io::Result::Ok(len.map(|len| got(&buf[..len])))
            })?;
            match received {
                Some(result) => break result,
                None => s.fill()?,
            }
        },
        _ => return Err(wrong_kind(what)),
    })
}

/// Hosted function: Host.socket_read!
#[no_mangle]
pub extern "C" fn roc_socket_read(socket: *mut u64, max: u64) -> HostSocketReadResult {
    bytes_result(with_socket(socket, |socket| read_stream(socket, max, "read", roc_bytes)))
}

/// Read from a stream and put what arrived into `list`, replacing its
/// contents or (with `keep`) after them. On an error the list is released.
fn read_to_list(
    socket: *mut u64,
    list: RocListWith<u8, false>,
    max: u64,
    keep: bool,
) -> NetResult<RocListWith<u8, false>> {
    let limit = max.min(MAX_READ_BYTES) as usize;
    let mut list = Some(list);
    let read = with_socket(socket, |socket| {
        read_stream(socket, max, "read_into", |bytes| {
            fill_list(list.take().expect("filled once"), keep, bytes, limit)
        })
    });
    // `fill_list` took the list on success; on failure it's still ours.
    if let Some(list) = list {
        unsafe { list.decref(roc_host()) };
    }
    read
}

/// Put `new_bytes` into `list`, replacing its contents or (with `keep`)
/// after them. Reuses the list's allocation when it can: when this is the
/// only reference to it (so no other Roc value can see the change), it's a
/// whole list rather than a slice of another, and there's room. Otherwise it
/// allocates a new list, leaving the old one untouched for anyone else
/// holding it.
fn fill_list(list: RocListWith<u8, false>, keep: bool, new_bytes: &[u8], max: usize) -> RocListWith<u8, false> {
    let kept = if keep { list.len() } else { 0 };
    let needed = kept + new_bytes.len();
    // has_one_ref, not is_unique: is_unique also accepts static data (a list
    // literal in the program), which must never be written to.
    let capacity = list.capacity_or_alloc_ptr >> 1;
    if !list.is_seamless_slice() && list.has_one_ref() && capacity >= needed {
        let mut list = list;
        unsafe { std::ptr::copy_nonoverlapping(new_bytes.as_ptr(), list.elements.add(kept), new_bytes.len()) };
        list.length = needed;
        return list;
    }
    // Room for the next read too: appending doubles, replacing sizes for `max`.
    let capacity = if keep { needed.max(kept.saturating_mul(2)).max(kept + max) } else { needed.max(max) };
    if capacity == 0 {
        unsafe { list.decref(roc_host()) };
        return RocListWith::empty();
    }
    let mut fresh = unsafe { RocListWith::<u8, false>::allocate(capacity, roc_host()) };
    unsafe {
        std::ptr::copy_nonoverlapping(list.as_slice().as_ptr(), fresh.elements, kept);
        std::ptr::copy_nonoverlapping(new_bytes.as_ptr(), fresh.elements.add(kept), new_bytes.len());
        list.decref(roc_host());
    }
    // Only the first `needed` elements are written; the length says so.
    fresh.length = needed;
    fresh
}

/// Hosted function: Host.socket_read_into!
#[no_mangle]
pub extern "C" fn roc_socket_read_into(socket: *mut u64, list: RocListWith<u8, false>, max: u64) -> HostSocketReadResult {
    bytes_result(read_to_list(socket, list, max, false))
}

/// Hosted function: Host.socket_read_append!
#[no_mangle]
pub extern "C" fn roc_socket_read_append(socket: *mut u64, list: RocListWith<u8, false>, max: u64) -> HostSocketReadResult {
    bytes_result(read_to_list(socket, list, max, true))
}

/// Hosted function: Host.socket_write!
#[no_mangle]
pub extern "C" fn roc_socket_write(socket: *mut u64, bytes: RocListWith<u8, false>) -> HostSocketSetTimeoutResult {
    let result = with_socket(socket, |socket| {
        let data = bytes.as_slice();
        match socket {
            Socket::TcpStream(s) => s.write_all(data)?,
            Socket::UnixStream(s) => s.write_all_with(data, |s, data| (&mut &*s).write(data))?,
            Socket::Udp(s) => check_datagram_sent(s.retry(true, s.write_deadline(), |s| s.send(data))?, data.len())?,
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
            Socket::TcpStream(s) => s.io.shutdown(how)?,
            Socket::UnixStream(s) => s.io.shutdown(how)?,
            Socket::Tls(s) => s.shutdown(how)?,
            _ => return Err(wrong_kind("shutdown")),
        }
        Ok(())
    }))
}

/// Hosted function: Host.socket_set_timeout!
#[no_mangle]
pub extern "C" fn roc_socket_set_timeout(socket: *mut u64, which: u8, timeout_ms: u64) -> HostSocketSetTimeoutResult {
    let read = which == 0;
    unit_result(with_socket(socket, |socket| {
        let set = |conn_read: &dyn Fn(u64), conn_write: &dyn Fn(u64)| {
            if read { conn_read(timeout_ms) } else { conn_write(timeout_ms) }
        };
        match socket {
            Socket::TcpStream(s) => set(&|ms| s.set_read_timeout_ms(ms), &|ms| s.set_write_timeout_ms(ms)),
            Socket::UnixStream(s) => set(&|ms| s.set_read_timeout_ms(ms), &|ms| s.set_write_timeout_ms(ms)),
            Socket::Udp(s) => set(&|ms| s.set_read_timeout_ms(ms), &|ms| s.set_write_timeout_ms(ms)),
            Socket::Tls(s) => set(&|ms| s.conn().set_read_timeout_ms(ms), &|ms| s.conn().set_write_timeout_ms(ms)),
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
            Socket::TcpListener(s, _) => s.io.local_addr()?.to_string(),
            Socket::TcpStream(s) => s.io.local_addr()?.to_string(),
            Socket::Udp(s) => s.io.local_addr()?.to_string(),
            Socket::UnixListener(s) => unix_path(s.listener.io.local_addr()?),
            Socket::UnixStream(s) => unix_path(s.io.local_addr()?),
            Socket::TlsListener(s) => s.listener.io.local_addr()?.to_string(),
            Socket::Tls(s) => s.tcp().local_addr()?.to_string(),
        })
    }))
}

/// Hosted function: Host.socket_peer_addr!
#[no_mangle]
pub extern "C" fn roc_socket_peer_addr(socket: *mut u64) -> HostSocketLocalAddrResult {
    str_result(with_socket(socket, |socket| {
        Ok(match socket {
            Socket::TcpStream(s) => s.io.peer_addr()?.to_string(),
            Socket::Udp(s) => s.io.peer_addr()?.to_string(),
            Socket::UnixStream(s) => unix_path(s.io.peer_addr()?),
            Socket::Tls(s) => s.tcp().peer_addr()?.to_string(),
            _ => return Err(wrong_kind("peer_addr")),
        })
    }))
}

/// Hosted function: Host.tcp_set_nodelay!
#[no_mangle]
pub extern "C" fn roc_tcp_set_nodelay(socket: *mut u64, enabled: bool) -> HostSocketSetTimeoutResult {
    unit_result(with_socket(socket, |socket| match socket {
        Socket::TcpStream(s) => Ok(s.io.set_nodelay(enabled)?),
        Socket::Tls(s) => Ok(s.tcp().set_nodelay(enabled)?),
        _ => Err(wrong_kind("set_nodelay")),
    }))
}

// --- UDP ---

fn with_udp<T>(handle: *mut u64, f: impl FnOnce(&Conn<UdpSocket>) -> NetResult<T>) -> NetResult<T> {
    with_socket(handle, |socket| match socket {
        Socket::Udp(s) => f(s),
        _ => Err(wrong_kind("this UDP operation")),
    })
}

/// Hosted function: Host.udp_connect!
#[no_mangle]
pub extern "C" fn roc_udp_connect(socket: *mut u64, address: RocStr) -> HostSocketSetTimeoutResult {
    unit_result(with_str(address, |address| {
        with_udp(socket, |s| {
            let addrs = crate::resolve::socket_addrs(address, None)?;
            Ok(s.io.connect(&addrs[..])?)
        })
    }))
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
            let addrs = crate::resolve::socket_addrs(address, None)?;
            let Some(addr) = addrs.first() else {
                return Err(NetErr::Io(io::Error::new(io::ErrorKind::NotFound, format!("{address} did not resolve to any address"))));
            };
            check_datagram_sent(s.retry(true, s.write_deadline(), |s| s.send_to(data, addr))?, data.len())
        })
    });
    unsafe { bytes.decref(roc_host()) };
    unit_result(result)
}

/// Hosted function: Host.udp_recv_from!
#[no_mangle]
pub extern "C" fn roc_udp_recv_from(socket: *mut u64, max: u64) -> HostUdpRecvFromResult {
    let result = with_udp(socket, |s| {
        Ok(s.read_with(|s| {
            with_scratch(max.min(MAX_READ_BYTES) as usize, |buf| {
                let (len, from): (usize, SocketAddr) = s.recv_from(buf)?;
                Ok(RocRecvFrom {
                    bytes: roc_bytes(&buf[..len]),
                    from: RocStr::from_str(&from.to_string(), roc_host()),
                })
            })
        })?)
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
    unit_result(with_udp(socket, |s| Ok(s.io.set_broadcast(enabled)?)))
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
                IpAddr::V4(g) => s.io.join_multicast_v4(&g, &Ipv4Addr::UNSPECIFIED)?,
                IpAddr::V6(g) => s.io.join_multicast_v6(&g, 0)?,
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
                IpAddr::V4(g) => s.io.leave_multicast_v4(&g, &Ipv4Addr::UNSPECIFIED)?,
                IpAddr::V6(g) => s.io.leave_multicast_v6(&g, 0)?,
            }
            Ok(())
        })
    }))
}

// --- Name resolution ---

/// Resolve `name` with the OS resolver before `deadline`, keeping each
/// address once, in the order the resolver returned them.
fn resolve(name: &str, deadline: Option<std::time::Instant>) -> NetResult<Vec<String>> {
    let mut addresses: Vec<String> = Vec::new();
    for ip in crate::resolve::host_ips(name, deadline)? {
        let ip = ip.to_string();
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
pub extern "C" fn roc_dns_resolve(name: RocStr, timeout_ms: u64) -> HostDnsResolveResult {
    let deadline = deadline_after(timeout_ms);
    let result = with_str(name, |name| resolve(name, deadline));
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
                    // One deadline for the name lookup, connecting, and the
                    // handshake together.
                    let deadline = deadline_after(timeout_ms);
                    let tcp = tcp_connect(address, deadline)?;
                    let name = if server_name.is_empty() { crate::tls::host_of(address) } else { server_name };
                    Ok(Socket::Tls(Box::new(crate::tls::client(tcp, name, ca_file, deadline)?)))
                })
            })
        })
    });
    handle_result(result)
}

/// Hosted function: Host.tls_listen!
#[no_mangle]
pub extern "C" fn roc_tls_listen(
    address: RocStr,
    cert_file: RocStr,
    key_file: RocStr,
    handshake_timeout_ms: u64,
    idle_ms: u64,
    write_ms: u64,
) -> HostSocketAcceptResult {
    let timeouts = ServerTimeouts { idle_ms, write_ms };
    let result = with_str(address, |address| {
        with_str(cert_file, |cert_file| {
            with_str(key_file, |key_file| {
                open_socket(|| {
                    let config = crate::tls::server_config(cert_file, key_file)?;
                    let listener = tcp_bind(address)?;
                    Ok(Socket::TlsListener(crate::sockets::TlsListener { listener, config, handshake_timeout_ms, timeouts }))
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
fn plain_tcp(socket: &Socket) -> NetResult<Conn<TcpStream>> {
    match socket {
        Socket::TcpStream(s) => {
            // A duplicate descriptor, so it gets its own event-queue
            // registrations; it's non-blocking already (that's shared), and
            // starts with the plain stream's timeouts.
            let tls = Conn::new(s.io.try_clone()?);
            s.timeouts().apply(&tls);
            Ok(tls)
        }
        _ => Err(wrong_kind("upgrading to TLS")),
    }
}

/// Hosted function: Host.tls_wrap_client!
#[no_mangle]
pub extern "C" fn roc_tls_wrap_client(
    socket: *mut u64,
    server_name: RocStr,
    ca_file: RocStr,
    timeout_ms: u64,
) -> HostSocketAcceptResult {
    let deadline = deadline_after(timeout_ms);
    let result = with_str(server_name, |server_name| {
        with_str(ca_file, |ca_file| {
            with_socket(socket, |socket| {
                let tcp = plain_tcp(socket)?;
                open_socket(|| Ok(Socket::Tls(Box::new(crate::tls::client(tcp, server_name, ca_file, deadline)?))))
            })
        })
    });
    handle_result(result)
}

/// Hosted function: Host.tls_wrap_server!
#[no_mangle]
pub extern "C" fn roc_tls_wrap_server(
    socket: *mut u64,
    cert_file: RocStr,
    key_file: RocStr,
    handshake_timeout_ms: u64,
) -> HostSocketAcceptResult {
    let deadline = deadline_after(handshake_timeout_ms);
    let result = with_str(cert_file, |cert_file| {
        with_str(key_file, |key_file| {
            with_socket(socket, |socket| {
                let tcp = plain_tcp(socket)?;
                let config = crate::tls::server_config(cert_file, key_file)?;
                open_socket(|| Ok(Socket::Tls(Box::new(crate::tls::server(tcp, config, deadline)?))))
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
