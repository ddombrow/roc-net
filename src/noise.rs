//! `Noise.Stream`: Noise transport messages over a TCP or Unix stream, after
//! a handshake done in Roc (platform/Noise.roc) hands over its cipher states.
//!
//! Each transport message is a frame: a 2-byte big-endian length, then that
//! many bytes of ciphertext (plaintext and a 16-byte tag), as libp2p-noise
//! frames them. Noise caps a message at 65,535 bytes, so a write is split
//! into as many messages as it takes.
//!
//! Full duplex, like `TlsStream`: reading and writing each have their own
//! lock (`sched::Lock`, which suspends a task rather than blocking its
//! worker), and their own cipher state, so one task can read while another
//! writes. The std mutexes around the cipher states are only held to
//! encrypt or decrypt, never across a socket wait.

use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::{Mutex, MutexGuard};

use aws_lc_rs::aead;

use crate::sched::Lock;
use crate::sockets::Conn;

/// The most a transport message holds: the frame limit less the tag.
const MAX_PLAINTEXT: usize = 65535 - 16;

/// The connection underneath.
pub enum Wire {
    Tcp(Conn<TcpStream>),
    Unix(Conn<UnixStream>),
}

impl Wire {
    fn read_some(&self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Wire::Tcp(c) => c.read_with(|s| (&mut &*s).read(buf)),
            Wire::Unix(c) => c.read_with(|s| (&mut &*s).read(buf)),
        }
    }

    fn write_all(&self, data: &[u8]) -> io::Result<()> {
        match self {
            Wire::Tcp(c) => c.write_all(data),
            Wire::Unix(c) => c.write_all_with(data, |s, data| (&mut &*s).write(data)),
        }
    }

    pub fn shutdown(&self, how: Shutdown) -> io::Result<()> {
        match self {
            Wire::Tcp(c) => c.io.shutdown(how),
            Wire::Unix(c) => c.io.shutdown(how),
        }
    }

    pub fn abort(&self) {
        match self {
            Wire::Tcp(c) => c.abort(),
            // No reset for Unix sockets.
            Wire::Unix(c) => {
                let _ = c.io.shutdown(Shutdown::Both);
            }
        }
    }

    pub fn set_read_timeout_ms(&self, ms: u64) {
        match self {
            Wire::Tcp(c) => c.set_read_timeout_ms(ms),
            Wire::Unix(c) => c.set_read_timeout_ms(ms),
        }
    }

    pub fn set_write_timeout_ms(&self, ms: u64) {
        match self {
            Wire::Tcp(c) => c.set_write_timeout_ms(ms),
            Wire::Unix(c) => c.set_write_timeout_ms(ms),
        }
    }

    pub fn read_deadline(&self) -> Option<std::time::Instant> {
        match self {
            Wire::Tcp(c) => c.read_deadline(),
            Wire::Unix(c) => c.read_deadline(),
        }
    }

    pub fn io_parts(&self) -> (std::os::fd::RawFd, &crate::sched::IoReg) {
        match self {
            Wire::Tcp(c) => c.io_parts(),
            Wire::Unix(c) => c.io_parts(),
        }
    }
}

/// One direction's cipher state: the key and the next nonce.
struct CipherState {
    key: aead::LessSafeKey,
    /// 0 for ChaChaPoly (the counter little-endian), 1 for AESGCM
    /// (big-endian), as the Noise spec lays out their nonces.
    cipher: u8,
    nonce: u64,
}

impl CipherState {
    fn new(cipher: u8, key: &[u8], nonce: u64) -> Option<CipherState> {
        let alg = match cipher {
            0 => &aead::CHACHA20_POLY1305,
            1 => &aead::AES_256_GCM,
            _ => return None,
        };
        let key = aead::LessSafeKey::new(aead::UnboundKey::new(alg, key).ok()?);
        Some(CipherState { key, cipher, nonce })
    }

    /// The nonce for this message, and the counter moved on. The last value
    /// (2^64 - 1) is reserved by the spec, so a state that reaches it is
    /// done.
    fn next_nonce(&mut self) -> io::Result<aead::Nonce> {
        if self.nonce == u64::MAX {
            return Err(io::Error::other("Noise: this stream has used up its nonces"));
        }
        let mut bytes = [0u8; 12];
        match self.cipher {
            0 => bytes[4..].copy_from_slice(&self.nonce.to_le_bytes()),
            _ => bytes[4..].copy_from_slice(&self.nonce.to_be_bytes()),
        }
        self.nonce += 1;
        Ok(aead::Nonce::assume_unique_for_key(bytes))
    }
}

struct Received {
    cipher: CipherState,
    /// Plaintext from the last message that a read hasn't taken yet.
    plain: Vec<u8>,
    taken: usize,
}

pub struct NoiseStream {
    wire: Wire,
    read_lock: Lock,
    write_lock: Lock,
    send: Mutex<CipherState>,
    receive: Mutex<Received>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl NoiseStream {
    /// A stream over `wire` with the handshake's cipher states: `cipher` (0
    /// ChaChaPoly, 1 AESGCM), and each direction's 32-byte key and next nonce.
    pub fn new(wire: Wire, cipher: u8, send: (&[u8], u64), receive: (&[u8], u64)) -> io::Result<NoiseStream> {
        let bad = || io::Error::new(io::ErrorKind::InvalidInput, "Noise: a cipher state's key isn't 32 bytes");
        Ok(NoiseStream {
            wire,
            read_lock: Lock::new(),
            write_lock: Lock::new(),
            send: Mutex::new(CipherState::new(cipher, send.0, send.1).ok_or_else(bad)?),
            receive: Mutex::new(Received {
                cipher: CipherState::new(cipher, receive.0, receive.1).ok_or_else(bad)?,
                plain: Vec::new(),
                taken: 0,
            }),
        })
    }

    pub fn wire(&self) -> &Wire {
        &self.wire
    }

    /// Read exactly `buf.len()` bytes; `Ok(false)` if the stream ended before
    /// the first, `UnexpectedEof` if it ended partway.
    fn read_exact_or_end(&self, buf: &mut [u8]) -> io::Result<bool> {
        let mut filled = 0;
        while filled < buf.len() {
            let n = self.wire.read_some(&mut buf[filled..])?;
            if n == 0 {
                if filled == 0 {
                    return Ok(false);
                }
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "Noise: the stream ended partway through a message"));
            }
            filled += n;
        }
        Ok(true)
    }

    /// Up to `max` bytes of plaintext, reading and decrypting the next
    /// message if none is left over; empty once the stream has ended.
    /// (Empty messages are skipped, so they can't look like the end.)
    ///
    /// A clean end at a message boundary can't be told from one an attacker
    /// forced by cutting the connection: Noise has no closing message, so a
    /// protocol that needs to know it got everything must say so itself.
    pub fn read(&self, max: usize) -> io::Result<Vec<u8>> {
        let _r = self.read_lock.lock();
        loop {
            {
                let mut received = lock(&self.receive);
                if received.taken < received.plain.len() {
                    let start = received.taken;
                    let end = (start + max).min(received.plain.len());
                    received.taken = end;
                    return Ok(received.plain[start..end].to_vec());
                }
            }
            let mut header = [0u8; 2];
            if !self.read_exact_or_end(&mut header)? {
                return Ok(Vec::new());
            }
            let len = u16::from_be_bytes(header) as usize;
            let mut message = vec![0u8; len];
            if !self.read_exact_or_end(&mut message)? && len > 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "Noise: the stream ended partway through a message"));
            }
            let mut received = lock(&self.receive);
            let nonce = received.cipher.next_nonce()?;
            let plain = received
                .cipher
                .key
                .open_in_place(nonce, aead::Aad::empty(), &mut message)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Noise: a message failed to authenticate"))?
                .to_vec();
            received.plain = plain;
            received.taken = 0;
        }
    }

    /// Encrypt and send all of `data`, as one message or (past 65,519 bytes)
    /// several.
    pub fn write_all(&self, data: &[u8]) -> io::Result<()> {
        let _w = self.write_lock.lock();
        for chunk in data.chunks(MAX_PLAINTEXT) {
            let frame = {
                let mut send = lock(&self.send);
                let nonce = send.next_nonce()?;
                let mut sealed = chunk.to_vec();
                send.key
                    .seal_in_place_append_tag(nonce, aead::Aad::empty(), &mut sealed)
                    .map_err(|_| io::Error::other("Noise: encrypting failed"))?;
                let mut frame = Vec::with_capacity(2 + sealed.len());
                frame.extend_from_slice(&(sealed.len() as u16).to_be_bytes());
                frame.extend_from_slice(&sealed);
                frame
            };
            self.wire.write_all(&frame)?;
        }
        Ok(())
    }
}

/// The connection behind a plain stream handle, for `Noise.wrap!`: a
/// duplicate descriptor with the plain stream's timeouts (as for TLS).
pub fn wire_of(socket: &crate::sockets::Socket) -> io::Result<Wire> {
    use crate::sockets::Socket;
    match socket {
        Socket::TcpStream(s) => {
            let dup = Conn::new(s.io.try_clone()?);
            s.timeouts().apply(&dup);
            Ok(Wire::Tcp(dup))
        }
        Socket::UnixStream(s) => {
            let dup = Conn::new(s.io.try_clone()?);
            s.timeouts().apply(&dup);
            Ok(Wire::Unix(dup))
        }
        _ => Err(io::Error::new(io::ErrorKind::InvalidInput, "Noise.wrap! works on TCP and Unix streams")),
    }
}
