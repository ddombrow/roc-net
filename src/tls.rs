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
//!   they can't deadlock each other.
//! - The handshake has its own lock, `handshake_lock`, and holds `inner`
//!   across its waits. Until the handshake is done, every path that does
//!   TLS I/O goes through `handshake()` (or, for `Select`, `handshake_now`,
//!   which only tries the lock), so none can reach `inner` meanwhile. It
//!   doesn't borrow the read and write locks: a task that waited for the
//!   handshake would then have to queue behind a reader holding the read
//!   lock across its wait for data, which deadlocked a proxy whose backend
//!   sends first.
//!
//! `read_lock` and `write_lock` are held across socket waits, so they're
//! `sched::Lock`s, which suspend a task rather than block its worker.
//!
//! Reading is split into `try_read`, which never waits (so it can use the
//! thread's scratch buffer), and `fill`, which does.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Instant;

use rustls::crypto::CryptoProvider;
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;
use rustls::{ClientConfig, ClientConnection, Connection, RootCertStore, ServerConfig, ServerConnection};
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, DnsName, PrivateKeyDer, ServerName};

use crate::sched::{Lock, LockGuard, TaskWaker, Waiters};
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
    /// Held by whichever task runs the handshake. Every path that does TLS
    /// I/O calls `handshake()` first until it's done, so this alone keeps
    /// them out of the way meanwhile.
    handshake_lock: Lock,
    handshaken: AtomicBool,
    /// Treat a connection that ends without close_notify as a normal end of
    /// stream, like OpenSSL's SSL_OP_IGNORE_UNEXPECTED_EOF.
    ignore_unexpected_eof: AtomicBool,
    /// Ended with [`abort`](TlsStream::abort): never send close_notify.
    aborted: AtomicBool,
    /// When the handshake must be finished by, if there's a limit.
    handshake_deadline: Option<Instant>,
    /// `Select`s waiting on this stream for progress that doesn't show on
    /// the socket: a lock being released (another reader may have left
    /// plaintext, a writer may have made room to send a reply, a handshake
    /// may have finished). Woken, all of them, each time the read, write or
    /// handshake lock is released.
    watchers: Mutex<Waiters>,
}

/// A held read or write lock that, once released, wakes the stream's
/// `Select` watchers.
struct Held<'a> {
    guard: Option<LockGuard<'a>>,
    watchers: &'a Mutex<Waiters>,
}

impl Drop for Held<'_> {
    fn drop(&mut self) {
        // Release first: a watcher woken before it would find it still held.
        drop(self.guard.take());
        lock(self.watchers).wake_all();
    }
}

/// Whether a `Select` must wait for a TLS stream, and on what (see
/// [`TlsStream::watch`]).
pub enum Watch {
    /// Progress is possible now: poll again.
    Ready,
    /// Registered under this id (remove with [`TlsStream::unwatch`]).
    /// `wants_write`: rustls has records to send, so also wait for the
    /// socket to be writable.
    Waiting { id: u64, wants_write: bool },
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
            handshake_lock: Lock::new(),
            handshaken: AtomicBool::new(false),
            ignore_unexpected_eof: AtomicBool::new(false),
            aborted: AtomicBool::new(false),
            handshake_deadline,
            watchers: Mutex::new(Waiters::new()),
        }
    }

    fn held<'a>(&'a self, guard: LockGuard<'a>) -> Held<'a> {
        Held { guard: Some(guard), watchers: &self.watchers }
    }

    fn lock_read(&self) -> Held<'_> {
        self.held(self.read_lock.lock())
    }

    fn lock_write(&self) -> Held<'_> {
        self.held(self.write_lock.lock())
    }

    fn try_lock_read(&self) -> Option<Held<'_>> {
        self.read_lock.try_lock().map(|guard| self.held(guard))
    }

    fn try_lock_write(&self) -> Option<Held<'_>> {
        self.write_lock.try_lock().map(|guard| self.held(guard))
    }

    fn lock_handshake(&self) -> Held<'_> {
        self.held(self.handshake_lock.lock())
    }

    fn try_lock_handshake(&self) -> Option<Held<'_>> {
        self.handshake_lock.try_lock().map(|guard| self.held(guard))
    }

    /// For a `Select` whose poll of this stream found nothing: register
    /// `waker` for lock releases, then check (after registering, so a change
    /// in between isn't missed) whether the stream already holds something
    /// a poll would take: ciphertext not yet decrypted, decrypted data, or
    /// the end of the session.
    pub fn watch(&self, waker: &TaskWaker) -> Watch {
        let id = lock(&self.watchers).add_waker(waker.clone());
        // Never wait for `inner`: the handshake holds it across socket waits,
        // and blocking this thread on it could stop that very handshake from
        // resuming. Held means a handshake (or a moment's processing) is under
        // way; its locks' release wakes this watcher.
        let mut inner = match self.inner.try_lock() {
            Ok(inner) => inner,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return Watch::Waiting { id, wants_write: false },
        };
        let buffered = !inner.pending.is_empty()
            || inner
                .conn
                .process_new_packets()
                .map_or(true, |state| state.plaintext_bytes_to_read() > 0 || state.peer_has_closed());
        // While another task holds the read lock, a poll couldn't take the
        // data anyway: wait for the release, which wakes this watcher.
        if buffered && self.handshaken.load(Ordering::Acquire) && !self.read_lock.is_locked() {
            drop(inner);
            self.unwatch(id);
            return Watch::Ready;
        }
        Watch::Waiting { id, wants_write: inner.conn.wants_write() }
    }

    pub fn unwatch(&self, id: u64) {
        lock(&self.watchers).remove(id);
    }

    pub fn set_ignore_unexpected_eof(&self, ignore: bool) {
        self.ignore_unexpected_eof.store(ignore, Ordering::Release);
    }

    /// The handshake deadline, while the handshake is still to finish.
    pub fn pending_handshake_deadline(&self) -> Option<Instant> {
        if self.handshaken.load(Ordering::Acquire) {
            None
        } else {
            self.handshake_deadline
        }
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
        // Its own lock, not the read and write locks: once the handshake is
        // done, a task that was waiting for it must not then queue behind a
        // reader holding the read lock while it waits for data. (That
        // deadlocked a proxy whose backend speaks first: the task writing the
        // greeting waited forever behind the task reading the client, which
        // was waiting for the greeting.)
        let _h = self.lock_handshake();
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
        let Some(_r) = self.try_lock_read() else {
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
        let _r = self.lock_read();
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

    /// `fill`, without ever waiting, for `Select`: make whatever progress is
    /// possible right now (handshake steps, pending records, ciphertext the
    /// socket already has) and return whether any was made. `Ok(false)` means
    /// progress needs the socket to become ready, or another task holds a
    /// lock this needs; the caller waits for the socket and tries again.
    pub fn fill_now(&self) -> io::Result<bool> {
        if !self.handshaken.load(Ordering::Acquire) {
            return self.handshake_now();
        }
        let Some(_r) = self.try_lock_read() else { return Ok(false) };
        let wants_write = lock(&self.inner).conn.wants_write();
        if wants_write {
            // Records to send in reply to what was read (an alert, a key
            // update): write what the socket takes now; rustls keeps the rest.
            let Some(_w) = self.try_lock_write() else { return Ok(false) };
            let mut inner = lock(&self.inner);
            return match inner.conn.write_tls(&mut &self.tcp.io) {
                Ok(_) => Ok(true),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => Ok(false),
                Err(err) => Err(err),
            };
        }
        {
            let mut inner = lock(&self.inner);
            if !inner.pending.is_empty() {
                return Ok(true);
            }
            let state = inner.conn.process_new_packets().map_err(tls_error)?;
            if state.plaintext_bytes_to_read() > 0 || state.peer_has_closed() {
                return Ok(true);
            }
        }
        let read = with_scratch(CHUNK + 2048, |raw| {
            let n = (&mut &self.tcp.io).read(raw)?;
            lock(&self.inner).pending.extend_from_slice(&raw[..n]);
            Ok::<_, io::Error>(n)
        });
        match read {
            Ok(0) => {
                let mut inner = lock(&self.inner);
                inner.conn.read_tls(&mut io::empty())?;
                inner.conn.process_new_packets().map_err(tls_error)?;
                Ok(true)
            }
            Ok(_) => Ok(true),
            Err(err) if matches!(err.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted) => Ok(false),
            Err(err) => Err(err),
        }
    }

    /// The handshake, as far as it can go without waiting: `Ok(true)` if it
    /// made progress (or finished), `Ok(false)` if it needs the peer (or the
    /// socket) first. The handshake deadline is checked on every call; a
    /// `Select` waiting on the stream bounds the wait itself with its own
    /// timeout.
    fn handshake_now(&self) -> io::Result<bool> {
        let Some(_h) = self.try_lock_handshake() else { return Ok(false) };
        let mut inner = lock(&self.inner);
        if self.handshaken.load(Ordering::Acquire) {
            return Ok(true);
        }
        if self.handshake_deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "TLS handshake timed out"));
        }
        let conn = &mut inner.conn;
        let mut progress = false;
        loop {
            if !conn.is_handshaking() && !conn.wants_write() {
                self.handshaken.store(true, Ordering::Release);
                return Ok(true);
            }
            if conn.wants_write() {
                match conn.write_tls(&mut &self.tcp.io) {
                    Ok(_) => {
                        progress = true;
                        continue;
                    }
                    Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(progress),
                    Err(err) => return Err(err),
                }
            }
            match conn.read_tls(&mut &self.tcp.io) {
                Ok(0) => {
                    return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed during the TLS handshake"))
                }
                Ok(_) => {
                    progress = true;
                    if let Err(err) = conn.process_new_packets() {
                        // Tell the peer why (a TLS alert), best effort.
                        let _ = conn.write_tls(&mut &self.tcp.io);
                        return Err(tls_error(err));
                    }
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(progress),
                Err(err) => return Err(err),
            }
        }
    }

    /// The name a client asked for (SNI), once the handshake is done,
    /// lower-cased and without a trailing dot; `None` if it sent none, and
    /// on a client stream.
    pub fn server_name(&self) -> io::Result<Option<String>> {
        self.handshake()?;
        Ok(match &lock(&self.inner).conn {
            // As certificates are chosen, so routing by it agrees.
            Connection::Server(conn) => conn.server_name().map(normalize_name),
            Connection::Client(_) => None,
        })
    }

    /// The application protocol agreed with ALPN, once the handshake is done.
    pub fn alpn_protocol(&self) -> io::Result<Option<Vec<u8>>> {
        self.handshake()?;
        Ok(lock(&self.inner).conn.alpn_protocol().map(<[u8]>::to_vec))
    }

    /// End the session without close_notify, resetting the TCP connection
    /// (see `Conn::abort`), so the peer can't mistake what it received for
    /// everything: for giving up partway through. Nothing is sent after this,
    /// not even when the stream is released.
    pub fn abort(&self) {
        self.aborted.store(true, Ordering::Release);
        self.tcp.abort();
    }

    /// Encrypt and send all of `data`.
    pub fn write_all(&self, data: &[u8]) -> io::Result<()> {
        self.handshake()?;
        let _w = self.lock_write();
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
        let _w = self.lock_write();
        let records = take_records(&mut lock(&self.inner).conn)?;
        self.tcp.write_all(&records)
    }

    /// Shutting down writing (or both) first sends close_notify, so the peer
    /// knows the data ended on purpose rather than being cut off.
    pub fn shutdown(&self, how: Shutdown) -> io::Result<()> {
        let aborted = self.aborted.load(Ordering::Acquire);
        if how != Shutdown::Read && self.handshaken.load(Ordering::Acquire) && !aborted {
            let _w = self.lock_write();
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
/// peer sees a deliberate end rather than a possibly truncated one, unless
/// it was aborted.
impl Drop for TlsStream {
    fn drop(&mut self) {
        if !self.handshaken.load(Ordering::Acquire) || self.aborted.load(Ordering::Acquire) {
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

/// A certificate or key file that can't be used, as `Other("path: reason")`
/// in Roc: a kind like `NotFound` would lose the path and the reason.
fn file_error(path: &str, err: impl std::fmt::Display) -> io::Error {
    io::Error::other(format!("{path}: {err}"))
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

fn alpn_ids(protocols: &[String]) -> Vec<Vec<u8>> {
    protocols.iter().map(|protocol| protocol.as_bytes().to_vec()).collect()
}

/// A client configuration: Mozilla's root certificates, or only the CA
/// certificate(s) in `ca_file` if one is given, offering `alpn`.
fn client_config(ca_file: &str, alpn: &[String]) -> io::Result<Arc<ClientConfig>> {
    let base = if ca_file.is_empty() {
        default_client_config()
    } else {
        let mut roots = RootCertStore::empty();
        for cert in load_certs(ca_file)? {
            roots.add(cert).map_err(|err| file_error(ca_file, err))?;
        }
        Arc::new(ClientConfig::builder().with_root_certificates(roots).with_no_client_auth())
    };
    if alpn.is_empty() {
        return Ok(base);
    }
    let mut config = (*base).clone();
    config.alpn_protocols = alpn_ids(alpn);
    Ok(Arc::new(config))
}

/// One certificate a server presents: to clients asking for `name` (SNI),
/// or, with an empty name, to the rest.
pub struct CertFiles {
    pub name: String,
    pub cert_file: String,
    pub key_file: String,
}

/// Picks a server's certificate by the name the client asked for: that
/// exact name, else a `*.` wildcard one label up, else the default (no name,
/// or a name with no certificate). rustls's `ResolvesServerCertUsingSni`
/// has no default, so a client connecting by IP address would be refused.
#[derive(Debug, Default)]
struct CertsByName {
    default: Option<Arc<CertifiedKey>>,
    by_name: HashMap<String, Arc<CertifiedKey>>,
}

impl CertsByName {
    fn lookup(&self, name: &str) -> Option<Arc<CertifiedKey>> {
        let name = normalize_name(name);
        if let Some(key) = self.by_name.get(&name) {
            return Some(key.clone());
        }
        let (_, parent) = name.split_once('.')?;
        self.by_name.get(&format!("*.{parent}")).cloned()
    }
}

impl ResolvesServerCert for CertsByName {
    fn resolve(&self, hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        hello.server_name().and_then(|name| self.lookup(name)).or_else(|| self.default.clone())
    }
}

/// DNS names compare without case or a trailing dot.
fn normalize_name(name: &str) -> String {
    name.trim_end_matches('.').to_ascii_lowercase()
}

/// A name a certificate can be chosen by: a DNS name, optionally starting
/// with `*.`. IP addresses never arrive as SNI, so they're refused rather
/// than silently never matching.
fn check_cert_name(name: &str) -> io::Result<()> {
    let host = name.strip_prefix("*.").unwrap_or(name);
    let is_dns = !host.is_empty()
        && host.parse::<std::net::IpAddr>().is_err()
        && DnsName::try_from(host).is_ok();
    if is_dns {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "{name:?} can't be a certificate's server name: it must be a DNS name, optionally starting with \"*.\""
        )))
    }
}

fn load_certified_key(files: &CertFiles, provider: &CryptoProvider) -> io::Result<CertifiedKey> {
    let certs = load_certs(&files.cert_file)?;
    let pem = fs::read(&files.key_file).map_err(|err| file_error(&files.key_file, err))?;
    let key = PrivateKeyDer::from_pem_slice(&pem).map_err(|err| file_error(&files.key_file, err))?;
    CertifiedKey::from_der(certs, key, provider).map_err(|err| match err {
        rustls::Error::InconsistentKeys(_) => io::Error::other(format!(
            "{}: the private key in {} doesn't match this certificate",
            files.cert_file, files.key_file
        )),
        err => file_error(&files.key_file, err),
    })
}

/// A server configuration presenting `certs` (see [`CertsByName`]) and
/// accepting the application protocols `alpn`.
pub fn server_config(certs: &[CertFiles], alpn: &[String]) -> io::Result<Arc<ServerConfig>> {
    let provider = rustls::crypto::aws_lc_rs::default_provider();
    let mut resolver = CertsByName::default();
    for files in certs {
        let key = Arc::new(load_certified_key(files, &provider)?);
        if files.name.is_empty() {
            resolver.default = Some(key);
        } else {
            check_cert_name(&files.name)?;
            resolver.by_name.insert(normalize_name(&files.name), key);
        }
    }
    let mut config = ServerConfig::builder_with_provider(Arc::new(provider))
        .with_safe_default_protocol_versions()
        .map_err(tls_error)?
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(resolver));
    config.alpn_protocols = alpn_ids(alpn);
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

/// Start a client session over `tcp` offering `alpn`, and complete the
/// handshake before `deadline`, so a bad certificate or an unresponsive peer
/// is reported here rather than on the first read or write.
pub fn client(
    tcp: Conn<TcpStream>,
    server_name: &str,
    ca_file: &str,
    alpn: &[String],
    deadline: Option<Instant>,
) -> io::Result<TlsStream> {
    let name = ServerName::try_from(server_name.to_string())
        .map_err(|err| io::Error::other(format!("{server_name:?} is not a valid server name: {err}")))?;
    let conn = ClientConnection::new(client_config(ca_file, alpn)?, name).map_err(tls_error)?;
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
