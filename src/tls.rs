//! TLS streams (rustls with the aws-lc-rs provider) that stay full-duplex:
//! one task can block reading while another writes, as with plain sockets.
//!
//! rustls is a single state machine, so it sits behind a mutex (`inner`), but
//! that lock is only held to encrypt or decrypt, never across a blocking
//! socket call:
//!
//! - `read_lock` serializes readers, so ciphertext is fed to rustls in the
//!   order it arrived. The socket read itself happens with only this held.
//! - `write_lock` serializes senders, so TLS records reach the socket in the
//!   order rustls produced them. The socket write happens with only this held.
//! - Locks are always taken in the order read_lock, write_lock, inner, so
//!   they can't deadlock each other. The handshake takes all three.

use std::fs;
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use rustls::{ClientConfig, ClientConnection, Connection, RootCertStore, ServerConfig, ServerConnection};
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer, ServerName};

/// Largest plaintext chunk handed to rustls at once (one TLS record's worth).
const CHUNK: usize = 16 * 1024;

struct Inner {
    conn: Connection,
    /// Ciphertext read from the socket that rustls hasn't taken yet.
    pending: Vec<u8>,
}

pub struct TlsStream {
    tcp: TcpStream,
    inner: Mutex<Inner>,
    read_lock: Mutex<()>,
    write_lock: Mutex<()>,
    handshaken: AtomicBool,
    /// Treat a connection that ends without close_notify as a normal end of
    /// stream, like OpenSSL's SSL_OP_IGNORE_UNEXPECTED_EOF.
    ignore_unexpected_eof: AtomicBool,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// rustls errors (bad certificates, protocol violations) as I/O errors.
fn tls_error(err: rustls::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, err)
}

impl TlsStream {
    fn new(tcp: TcpStream, conn: Connection) -> Self {
        TlsStream {
            tcp,
            inner: Mutex::new(Inner { conn, pending: Vec::new() }),
            read_lock: Mutex::new(()),
            write_lock: Mutex::new(()),
            handshaken: AtomicBool::new(false),
            ignore_unexpected_eof: AtomicBool::new(false),
        }
    }

    pub fn set_ignore_unexpected_eof(&self, ignore: bool) {
        self.ignore_unexpected_eof.store(ignore, Ordering::Release);
    }

    pub fn tcp(&self) -> &TcpStream {
        &self.tcp
    }

    /// Run the handshake if it hasn't happened yet.
    pub fn handshake(&self) -> io::Result<()> {
        if self.handshaken.load(Ordering::Acquire) {
            return Ok(());
        }
        let _r = lock(&self.read_lock);
        let _w = lock(&self.write_lock);
        let mut inner = lock(&self.inner);
        while inner.conn.is_handshaking() {
            inner.conn.complete_io(&mut &self.tcp)?;
        }
        // TLS 1.3 servers send session tickets right after the handshake.
        while inner.conn.wants_write() {
            inner.conn.write_tls(&mut &self.tcp)?;
        }
        self.handshaken.store(true, Ordering::Release);
        Ok(())
    }

    /// Read decrypted bytes. `Ok(0)` means the peer closed the TLS session
    /// properly (close_notify); a connection that just drops fails with
    /// `UnexpectedEof`, since that can mean an attacker cut the data short.
    pub fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        self.handshake()?;
        let _r = lock(&self.read_lock);
        let mut raw = vec![0u8; CHUNK + 2048];
        loop {
            let reply_needed = {
                let mut inner = lock(&self.inner);
                match inner.conn.reader().read(buf) {
                    Ok(n) => return Ok(n),
                    Err(err) if err.kind() == io::ErrorKind::WouldBlock => {}
                    Err(err)
                        if err.kind() == io::ErrorKind::UnexpectedEof
                            && self.ignore_unexpected_eof.load(Ordering::Acquire) =>
                    {
                        return Ok(0)
                    }
                    Err(err) => return Err(err),
                }
                if inner.pending.is_empty() {
                    None
                } else {
                    // Feed rustls what it can take; keep the rest for later.
                    let Inner { conn, pending } = &mut *inner;
                    let mut unread: &[u8] = pending;
                    conn.read_tls(&mut unread)?;
                    let consumed = pending.len() - unread.len();
                    pending.drain(..consumed);
                    conn.process_new_packets().map_err(tls_error)?;
                    Some(conn.wants_write())
                }
            };
            match reply_needed {
                // rustls produced output while reading (an alert, a key
                // update): send it, then look for plaintext again.
                Some(true) => self.send_pending()?,
                Some(false) => {}
                None => {
                    // Nothing buffered: wait for ciphertext without holding
                    // `inner`, so writers can keep going.
                    let n = (&self.tcp).read(&mut raw)?;
                    let mut inner = lock(&self.inner);
                    if n == 0 {
                        // Tell rustls the connection ended.
                        inner.conn.read_tls(&mut io::empty())?;
                        inner.conn.process_new_packets().map_err(tls_error)?;
                    } else {
                        inner.pending.extend_from_slice(&raw[..n]);
                    }
                }
            }
        }
    }

    /// Encrypt and send all of `data`.
    pub fn write_all(&self, data: &[u8]) -> io::Result<()> {
        self.handshake()?;
        let _w = lock(&self.write_lock);
        for chunk in data.chunks(CHUNK) {
            let records = {
                let mut inner = lock(&self.inner);
                inner.conn.writer().write_all(chunk)?;
                take_records(&mut inner.conn)?
            };
            (&self.tcp).write_all(&records)?;
        }
        Ok(())
    }

    /// Send whatever TLS records rustls has queued.
    fn send_pending(&self) -> io::Result<()> {
        let _w = lock(&self.write_lock);
        let records = take_records(&mut lock(&self.inner).conn)?;
        (&self.tcp).write_all(&records)
    }

    /// Shutting down writing (or both) first sends close_notify, so the peer
    /// knows the data ended on purpose rather than being cut off.
    pub fn shutdown(&self, how: Shutdown) -> io::Result<()> {
        if how != Shutdown::Read && self.handshaken.load(Ordering::Acquire) {
            {
                let _w = lock(&self.write_lock);
                let records = {
                    let mut inner = lock(&self.inner);
                    inner.conn.send_close_notify();
                    take_records(&mut inner.conn)?
                };
                // The peer may already be gone; closing continues regardless.
                let _ = (&self.tcp).write_all(&records);
            }
        }
        self.tcp.shutdown(how)
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
            // Best effort: the peer may already be gone.
            let _ = (&self.tcp).write_all(&records);
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

/// Start a client session over `tcp` and complete the handshake, so a bad
/// certificate is reported here rather than on the first read or write.
pub fn client(tcp: TcpStream, server_name: &str, ca_file: &str, timeout: Option<Duration>) -> io::Result<TlsStream> {
    let name = ServerName::try_from(server_name.to_string()).map_err(|err| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("{server_name:?} is not a valid server name: {err}"))
    })?;
    let conn = ClientConnection::new(client_config(ca_file)?, name).map_err(tls_error)?;
    let stream = TlsStream::new(tcp, Connection::Client(conn));
    stream.tcp.set_read_timeout(timeout)?;
    stream.tcp.set_write_timeout(timeout)?;
    stream.handshake()?;
    stream.tcp.set_read_timeout(None)?;
    stream.tcp.set_write_timeout(None)?;
    Ok(stream)
}

/// Start a server session over `tcp`. The handshake happens on the first
/// read or write, in whichever task uses the stream, so a slow client can't
/// hold up the task that accepted it.
pub fn server(tcp: TcpStream, config: Arc<ServerConfig>) -> io::Result<TlsStream> {
    let conn = ServerConnection::new(config).map_err(tls_error)?;
    Ok(TlsStream::new(tcp, Connection::Server(conn)))
}
