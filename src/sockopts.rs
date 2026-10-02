//! Socket options on open sockets: TCP keepalive, buffer sizes, and Unix
//! peer credentials. They apply to the descriptor under a stream, so a TLS
//! or Noise stream's options are its TCP connection's.

use std::io;
use std::mem::ManuallyDrop;
use std::os::fd::{BorrowedFd, RawFd};
use std::time::Duration;

use crate::net::{with_socket, FromNetErr, NetErr};
use crate::roc_platform_abi::{
    AnonStruct4a9a39232e571b2c as RocCredentials, HostFileDeleteResult, HostFileDeleteResultPayload,
    HostFileDeleteResultTag, HostSocketBufferSizeResult, HostSocketBufferSizeResultPayload, HostSocketBufferSizeResultTag,
    HostUnixPeerCredentialsResult, HostUnixPeerCredentialsResultPayload, HostUnixPeerCredentialsResultTag,
};
use crate::sockets::Socket;

/// The descriptor whose options a socket's are.
fn fd_of(socket: &Socket) -> RawFd {
    socket.io_parts().0
}

/// Run `f` with the socket behind `handle` as a `socket2` reference.
fn with_sock<T>(handle: *mut u64, f: impl FnOnce(socket2::SockRef<'_>) -> io::Result<T>) -> Result<T, NetErr> {
    with_socket(handle, |socket| {
        let fd = unsafe { BorrowedFd::borrow_raw(fd_of(socket)) };
        Ok(f(socket2::SockRef::from(&fd))?)
    })
}

fn unit_result(value: Result<(), NetErr>) -> HostFileDeleteResult {
    match value {
        Ok(()) => HostFileDeleteResult { payload: HostFileDeleteResultPayload { ok: [] }, tag: HostFileDeleteResultTag::Ok },
        Err(err) => HostFileDeleteResult {
            payload: HostFileDeleteResultPayload { err: ManuallyDrop::new(FromNetErr::from_net_err(err)) },
            tag: HostFileDeleteResultTag::Err,
        },
    }
}

/// Hosted function: Host.socket_set_keepalive!
#[no_mangle]
pub extern "C" fn roc_socket_set_keepalive(
    handle: *mut u64,
    enabled: bool,
    idle_secs: u64,
    interval_secs: u64,
    probes: u32,
) -> HostFileDeleteResult {
    unit_result(with_sock(handle, |sock| {
        if !enabled {
            return sock.set_keepalive(false);
        }
        if idle_secs == 0 || interval_secs == 0 || probes == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "keepalive needs idle_secs, interval_secs and probes above 0"));
        }
        let keepalive = socket2::TcpKeepalive::new()
            .with_time(Duration::from_secs(idle_secs))
            .with_interval(Duration::from_secs(interval_secs))
            .with_retries(probes);
        sock.set_tcp_keepalive(&keepalive)
    }))
}

/// Hosted function: Host.socket_set_buffer_size! (`which`: 0 receive, 1 send).
#[no_mangle]
pub extern "C" fn roc_socket_set_buffer_size(handle: *mut u64, which: u8, bytes: u64) -> HostFileDeleteResult {
    let bytes = bytes.min(i32::MAX as u64) as usize;
    unit_result(with_sock(handle, |sock| match which {
        0 => sock.set_recv_buffer_size(bytes),
        _ => sock.set_send_buffer_size(bytes),
    }))
}

/// Hosted function: Host.socket_buffer_size!
#[no_mangle]
pub extern "C" fn roc_socket_buffer_size(handle: *mut u64, which: u8) -> HostSocketBufferSizeResult {
    let size = with_sock(handle, |sock| match which {
        0 => sock.recv_buffer_size(),
        _ => sock.send_buffer_size(),
    });
    match size {
        Ok(size) => HostSocketBufferSizeResult {
            payload: HostSocketBufferSizeResultPayload { ok: ManuallyDrop::new(size as u64) },
            tag: HostSocketBufferSizeResultTag::Ok,
        },
        Err(err) => HostSocketBufferSizeResult {
            payload: HostSocketBufferSizeResultPayload { err: ManuallyDrop::new(FromNetErr::from_net_err(err)) },
            tag: HostSocketBufferSizeResultTag::Err,
        },
    }
}

/// The user, group and (where the system says) process of the peer of the
/// Unix socket `fd`, as recorded when it connected.
fn peer_credentials(fd: RawFd) -> io::Result<RocCredentials> {
    #[cfg(target_os = "linux")]
    {
        let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_PEERCRED, &mut cred as *mut _ as *mut libc::c_void, &mut len)
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(RocCredentials { uid: cred.uid, gid: cred.gid, pid: if cred.pid > 0 { cred.pid } else { -1 } })
    }
    #[cfg(target_os = "macos")]
    {
        let (mut uid, mut gid) = (0, 0);
        if unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut pid: libc::pid_t = -1;
        let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(fd, libc::SOL_LOCAL, libc::LOCAL_PEERPID, &mut pid as *mut _ as *mut libc::c_void, &mut len)
        };
        Ok(RocCredentials { uid, gid, pid: if rc == 0 && pid > 0 { pid } else { -1 } })
    }
}

/// Hosted function: Host.unix_peer_credentials!
#[no_mangle]
pub extern "C" fn roc_unix_peer_credentials(handle: *mut u64) -> HostUnixPeerCredentialsResult {
    let creds = with_socket(handle, |socket| match socket {
        Socket::UnixStream(s) => Ok(peer_credentials(s.io_parts().0)?),
        _ => Err(NetErr::Io(io::Error::new(io::ErrorKind::InvalidInput, "peer credentials are for Unix streams"))),
    });
    match creds {
        Ok(creds) => HostUnixPeerCredentialsResult {
            payload: HostUnixPeerCredentialsResultPayload { ok: ManuallyDrop::new(creds) },
            tag: HostUnixPeerCredentialsResultTag::Ok,
        },
        Err(err) => HostUnixPeerCredentialsResult {
            payload: HostUnixPeerCredentialsResultPayload { err: ManuallyDrop::new(FromNetErr::from_net_err(err)) },
            tag: HostUnixPeerCredentialsResultTag::Err,
        },
    }
}
