//! TLS streams (rustls with the aws-lc-rs provider) that stay full-duplex:
//! one task can wait to read while another writes, as with plain sockets.
//!
//! rustls is a single state machine, so it sits behind a mutex (`inner`), but
//! that lock is only held to encrypt or decrypt, never across a socket wait:
//!
//! - `read_lock` serializes readers, so ciphertext is fed to rustls in the
//!   order it arrived. The socket read itself happens with only this held.
//! - `write_lock` serializes senders, so TLS records reach the socket in the
//!   order rustls produced them. The socket write happens with only this held.
//! - Locks are always taken in the order read_lock, write_lock, inner, so
//!   they can't deadlock each other. The handshake takes all three, so it's
//!   the one place `inner` is held across waits: nobody else can reach it
//!   then without first waiting for one of the others.
//!
//! `read_lock` and `write_lock` are held across socket waits, so they're
//! `sched::Lock`s, which suspend a task rather than block its worker.
//!
//! Reading is split into `try_read`, which never waits (so it can use the
//! thread's scratch buffer), and `fill`, which does.

use std::fs;
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Instant;

use rustls::{ClientConfig, ClientConnection, Connection, RootCertStore, ServerConfig, ServerConnection};
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer, ServerName};

use crate::sched::Lock;
use crate::sockets::{with_scratch, Conn};

/// Largest plaintext chunk handed to rustls at once (one TLS record's worth).
const CHUNK: usize = 16 * 1024;

struct Inner {
    conn: Connection,
    /// Ciphertext read from the socket that rustls hasn't taken yet.
    pending: Vec<u8>,
}

pub struct TlsStream {
    tcp: Conn<TcpStream>,
    inner: Mutex<Inner>,
    read_lock: Lock,
    write_lock: Lock,
    handshaken: AtomicBool,
    /// Treat a connection that ends without close_notify as a normal end of
    /// stream, like OpenSSL's SSL_OP_IGNORE_UNEXPECTED_EOF.
    ignore_unexpected_eof: AtomicBool,
    /// When the handshake must be finished by, if there's a limit.
    handshake_deadline: Option<Instant>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// rustls errors (bad certificates, protocol violations) as I/O errors.
fn tls_error(err: rustls::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, err)
}

/// The socket as rustls sees it during the handshake: reads and writes that
/// wait until `deadline` if there is one, otherwise under the socket's own
/// timeouts.
struct Wire<'a> {
    tcp: &'a Conn<TcpStream>,
    deadline: Option<Instant>,
}

impl Read for Wire<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let deadline = self.deadline.or_else(|| self.tcp.read_deadline());
        self.tcp.retry(false, deadline, |s| (&mut &*s).read(buf))
    }
}

impl Write for Wire<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let deadline = self.deadline.or_else(|| self.tcp.write_deadline());
        self.tcp.retry(true, deadline, |s| (&mut &*s).write(buf))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl TlsStream {
    fn new(tcp: Conn<TcpStream>, conn: Connection, handshake_deadline: Option<Instant>) -> Self {
        TlsStream {
            tcp,
            inner: Mutex::new(Inner { conn, pending: Vec::new() }),
            read_lock: Lock::new(),
            write_lock: Lock::new(),
            handshaken: AtomicBool::new(false),
            ignore_unexpected_eof: AtomicBool::new(false),
            handshake_deadline,
        }
    }

    pub fn set_ignore_unexpected_eof(&self, ignore: bool) {
        self.ignore_unexpected_eof.store(ignore, Ordering::Release);
    }

    pub fn tcp(&self) -> &TcpStream {
        &self.tcp.io
    }

    pub fn conn(&self) -> &Conn<TcpStream> {
        &self.tcp
    }

    /// Run the handshake if it hasn't happened yet: clients do this when
    /// connecting, servers on the stream's first read or write.
    ///
    /// With a deadline, the handshake as a whole is bounded: a peer that
    /// stalls, or trickles bytes to keep each read alive (slowloris), fails
    /// with `TimedOut` once the deadline passes. Without one, each read and
    /// write gets the socket's own timeouts.
    pub fn handshake(&self) -> io::Result<()> {
        if self.handshaken.load(Ordering::Acquire) {
            return Ok(());
        }
        let _r = self.read_lock.lock();
        let _w = self.write_lock.lock();
        let mut inner = lock(&self.inner);
        if self.handshaken.load(Ordering::Acquire) {
            // Another task finished it while this one waited for the locks.
            return Ok(());
        }
        self.run_handshake(&mut inner.conn)
    }

    fn run_handshake(&self, conn: &mut Connection) -> io::Result<()> {
        let deadline = self.handshake_deadline;
        let mut wire = Wire { tcp: &self.tcp, deadline };
        // Also send what's left after the handshake completes, such as the
        // session tickets TLS 1.3 servers send right after it.
        while conn.is_handshaking() || conn.wants_write() {
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "TLS handshake timed out"));
            }
            if conn.wants_write() {
                conn.write_tls(&mut wire)?;
                continue;
            }
            if conn.read_tls(&mut wire)? == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed during the TLS handshake"));
            }
            if let Err(err) = conn.process_new_packets() {
                // Tell the peer why (a TLS alert), best effort.
                while conn.wants_write() && conn.write_tls(&mut wire).is_ok() {}
                return Err(tls_error(err));
            }
        }
        self.handshaken.store(true, Ordering::Release);
        Ok(())
    }

    /// Read decrypted bytes already received, without waiting: `None` means
    /// there are none yet, and [`fill`](Self::fill) must run first. `Some(0)`
    /// means the peer closed the TLS session properly (close_notify); a
    /// connection that just drops fails with `UnexpectedEof`, since that can
    /// mean an attacker cut the data short.
    ///
    /// Split from `fill` so the caller can read into its thread's scratch
    /// buffer, which mustn't be held across a wait.
    /// Never waits: before the handshake is done, or while another reader
    /// holds the read lock, it returns `None` too, and `fill` does the
    /// waiting.
    pub fn try_read(&self, buf: &mut [u8]) -> io::Result<Option<usize>> {
        if !self.handshaken.load(Ordering::Acquire) {
            return Ok(None);
        }
        let Some(_r) = self.read_lock.try_lock() else {
            return Ok(None);
        };
        let mut inner = lock(&self.inner);
        loop {
            match inner.conn.reader().read(buf) {
                Ok(n) => return Ok(Some(n)),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {}
                Err(err)
                    if err.kind() == io::ErrorKind::UnexpectedEof
                        && self.ignore_unexpected_eof.load(Ordering::Acquire) =>
                {
                    return Ok(Some(0))
                }
                Err(err) => return Err(err),
            }
            if inner.pending.is_empty() {
                return Ok(None);
            }
            // Feed rustls what it can take; keep the rest for later.
            let Inner { conn, pending } = &mut *inner;
            let mut unread: &[u8] = pending;
            conn.read_tls(&mut unread)?;
            let consumed = pending.len() - unread.len();
            pending.drain(..consumed);
            conn.process_new_packets().map_err(tls_error)?;
            if conn.wants_write() {
                // rustls produced output while reading (an alert, a key
                // update): `fill` sends it.
                return Ok(None);
            }
        }
    }

    /// Make progress towards `try_read` having something: send what rustls
    /// has queued in reply to what it read, or else wait for more ciphertext.
    pub fn fill(&self) -> io::Result<()> {
        if !self.handshaken.load(Ordering::Acquire) {
            return self.handshake();
        }
        let _r = self.read_lock.lock();
        {
            let mut inner = lock(&self.inner);
            if inner.conn.wants_write() {
                drop(inner);
                return self.send_pending();
            }
            if !inner.pending.is_empty() {
                return Ok(());
            }
            // Another reader may have received what this one is after.
            let state = inner.conn.process_new_packets().map_err(tls_error)?;
            if state.plaintext_bytes_to_read() > 0 || state.peer_has_closed() {
                return Ok(());
            }
        }
        let n = self.tcp.read_with(|s| {
            with_scratch(CHUNK + 2048, |raw| {
                let n = (&mut &*s).read(raw)?;
                lock(&self.inner).pending.extend_from_slice(&raw[..n]);
                Ok(n)
            })
        })?;
        if n == 0 {
            // Tell rustls the connection ended.
            let mut inner = lock(&self.inner);
            inner.conn.read_tls(&mut io::empty())?;
            inner.conn.process_new_packets().map_err(tls_error)?;
        }
        Ok(())
    }

    /// Encrypt and send all of `data`.
    pub fn write_all(&self, data: &[u8]) -> io::Result<()> {
        self.handshake()?;
        let _w = self.write_lock.lock();
        for chunk in data.chunks(CHUNK) {
            let records = {
                let mut inner = lock(&self.inner);
                inner.conn.writer().write_all(chunk)?;
                take_records(&mut inner.conn)?
            };
            self.tcp.write_all(&records)?;
        }
        Ok(())
    }

    /// Send whatever TLS records rustls has queued.
    fn send_pending(&self) -> io::Result<()> {
        let _w = self.write_lock.lock();
        let records = take_records(&mut lock(&self.inner).conn)?;
        self.tcp.write_all(&records)
    }

    /// Shutting down writing (or both) first sends close_notify, so the peer
    /// knows the data ended on purpose rather than being cut off.
    pub fn shutdown(&self, how: Shutdown) -> io::Result<()> {
        if how != Shutdown::Read && self.handshaken.load(Ordering::Acquire) {
            let _w = self.write_lock.lock();
            let records = {
                let mut inner = lock(&self.inner);
                inner.conn.send_close_notify();
                take_records(&mut inner.conn)?
            };
            // The peer may already be gone; closing continues regardless.
            let _ = self.tcp.write_all(&records);
        }
        self.tcp.io.shutdown(how)
    }
}

/// A stream released without `close!` still ends the session properly, so the
/// peer sees a deliberate end rather than a possibly truncated one.
impl Drop for TlsStream {
    fn drop(&mut self) {
        if !self.handshaken.load(Ordering::Acquire) {
            return;
        }
        let conn = &mut self.inner.get_mut().unwrap_or_else(|poisoned| poisoned.into_inner()).conn;
        conn.send_close_notify();
        if let Ok(records) = take_records(conn) {
            // Best effort, without waiting (this runs while Roc releases the
            // stream): a full send buffer or a departed peer drops it.
            let _ = (&mut &self.tcp.io).write_all(&records);
        }
    }
}

fn take_records(conn: &mut Connection) -> io::Result<Vec<u8>> {
    let mut records = Vec::new();
    while conn.wants_write() {
        conn.write_tls(&mut records)?;
    }
    Ok(records)
}

// --- Configuration ---

fn default_client_config() -> Arc<ClientConfig> {
    static CONFIG: OnceLock<Arc<ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            Arc::new(ClientConfig::builder().with_root_certificates(roots).with_no_client_auth())
        })
        .clone()
}

fn file_error(path: &str, err: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, format!("{path}: {err}"))
}

fn load_certs(path: &str) -> io::Result<Vec<CertificateDer<'static>>> {
    let pem = fs::read(path).map_err(|err| file_error(path, err))?;
    let certs = CertificateDer::pem_slice_iter(&pem)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|err| file_error(path, err))?;
    if certs.is_empty() {
        return Err(file_error(path, "no certificates found"));
    }
    Ok(certs)
}

/// A client configuration: Mozilla's root certificates, or only the CA
/// certificate(s) in `ca_file` if one is given.
fn client_config(ca_file: &str) -> io::Result<Arc<ClientConfig>> {
    if ca_file.is_empty() {
        return Ok(default_client_config());
    }
    let mut roots = RootCertStore::empty();
    for cert in load_certs(ca_file)? {
        roots.add(cert).map_err(|err| file_error(ca_file, err))?;
    }
    Ok(Arc::new(ClientConfig::builder().with_root_certificates(roots).with_no_client_auth()))
}

pub fn server_config(cert_file: &str, key_file: &str) -> io::Result<Arc<ServerConfig>> {
    let certs = load_certs(cert_file)?;
    let pem = fs::read(key_file).map_err(|err| file_error(key_file, err))?;
    let key = PrivateKeyDer::from_pem_slice(&pem).map_err(|err| file_error(key_file, err))?;
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|err| file_error(cert_file, err))?;
    Ok(Arc::new(config))
}

/// The host part of `"host:port"` or `"[v6]:port"`, for server name checks.
pub fn host_of(address: &str) -> &str {
    if let Some(rest) = address.strip_prefix('[') {
        return rest.split(']').next().unwrap_or(rest);
    }
    match address.rsplit_once(':') {
        Some((host, _port)) => host,
        None => address,
    }
}

/// Start a client session over `tcp` and complete the handshake before
/// `deadline`, so a bad certificate or an unresponsive peer is reported here
/// rather than on the first read or write.
pub fn client(tcp: Conn<TcpStream>, server_name: &str, ca_file: &str, deadline: Option<Instant>) -> io::Result<TlsStream> {
    let name = ServerName::try_from(server_name.to_string()).map_err(|err| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("{server_name:?} is not a valid server name: {err}"))
    })?;
    let conn = ClientConnection::new(client_config(ca_file)?, name).map_err(tls_error)?;
    let stream = TlsStream::new(tcp, Connection::Client(conn), deadline);
    stream.handshake()?;
    Ok(stream)
}

/// Start a server session over `tcp`. The handshake happens on the first
/// read or write, in whichever task uses the stream, so a slow client can't
/// hold up the task that accepted it; it must finish by `deadline`, which the
/// caller counts from when the connection was accepted.
pub fn server(tcp: Conn<TcpStream>, config: Arc<ServerConfig>, deadline: Option<Instant>) -> io::Result<TlsStream> {
    let conn = ServerConnection::new(config).map_err(tls_error)?;
    Ok(TlsStream::new(tcp, Connection::Server(conn), deadline))
}
