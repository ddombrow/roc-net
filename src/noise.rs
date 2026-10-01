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
//!
//! Ciphertext read from the socket is kept until it makes a whole message,
//! so a read can stop partway through one (a timeout, or `Select` finding
//! only part of it arrived) and the next carries on from there.

use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::{Mutex, MutexGuard};
use std::time::Instant;

use aws_lc_rs::aead;

use crate::sched::{Lock, LockGuard, TaskWaker, Waiters};
use crate::sockets::{with_scratch, Conn};

/// The most a transport message holds: the frame limit less the tag.
const MAX_PLAINTEXT: usize = 65535 - 16;

/// Most ciphertext to ask the socket for at once: a whole message and its
/// length (with more, the rest waits for the next read).
const READ_CHUNK: usize = 65535 + 2;

/// The connection underneath.
pub enum Wire {
    Tcp(Conn<TcpStream>),
    Unix(Conn<UnixStream>),
}

impl Wire {
    /// Read what has arrived, waiting for something until `deadline` (or the
    /// read timeout, whichever is first), into `got`.
    fn read_by(&self, deadline: Option<Instant>, got: &mut Vec<u8>) -> io::Result<usize> {
        fn read<S>(c: &Conn<S>, deadline: Option<Instant>, got: &mut Vec<u8>) -> io::Result<usize>
        where
            S: std::os::fd::AsRawFd,
            for<'a> &'a S: Read,
        {
            let deadline = crate::sockets::earliest(c.read_deadline(), deadline);
            c.retry(false, deadline, |s| {
                with_scratch(READ_CHUNK, |buf| {
                    let n = (&mut &*s).read(buf)?;
                    got.extend_from_slice(&buf[..n]);
                    Ok(n)
                })
            })
        }
        match self {
            Wire::Tcp(c) => read(c, deadline, got),
            Wire::Unix(c) => read(c, deadline, got),
        }
    }

    /// Read what has arrived into `got` without waiting: `None` if nothing has.
    fn read_now(&self, got: &mut Vec<u8>) -> io::Result<Option<usize>> {
        loop {
            let read: io::Result<usize> = with_scratch(READ_CHUNK, |buf| {
                let n = match self {
                    Wire::Tcp(c) => (&mut &c.io).read(buf),
                    Wire::Unix(c) => (&mut &c.io).read(buf),
                }?;
                got.extend_from_slice(&buf[..n]);
                Ok(n)
            });
            match read {
                Ok(n) => return Ok(Some(n)),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(None),
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(err) => return Err(err),
            }
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
    /// Ciphertext from the socket not yet decrypted: part of a message, or
    /// whole ones (with the start of the next) read along with the last.
    ciphertext: Vec<u8>,
    /// The socket has reached its end.
    ended: bool,
    /// A message failed to authenticate: every later read fails the same
    /// way. Carrying on would skip the bad message (its nonce is used up),
    /// so the next one would decrypt and the loss would go unnoticed.
    failed: bool,
}

fn not_authentic() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Noise: a message failed to authenticate")
}

impl Received {
    /// Up to `max` bytes of the plaintext left over, if there is any.
    fn take(&mut self, max: usize) -> Option<Vec<u8>> {
        if self.taken >= self.plain.len() {
            return None;
        }
        let start = self.taken;
        let end = (start + max).min(self.plain.len());
        self.taken = end;
        Some(self.plain[start..end].to_vec())
    }

    /// The length of the whole message at the front of `ciphertext`, if one
    /// has arrived.
    fn whole_message(&self) -> Option<usize> {
        let header: [u8; 2] = self.ciphertext.get(..2)?.try_into().ok()?;
        let len = u16::from_be_bytes(header) as usize;
        (self.ciphertext.len() >= 2 + len).then_some(len)
    }

    /// Whether a read would return without waiting: plaintext, a message to
    /// decrypt, or the end.
    fn readable(&self) -> bool {
        self.taken < self.plain.len() || self.whole_message().is_some() || self.ended || self.failed
    }

    /// What a read returns without waiting: plaintext, decrypting messages
    /// that have arrived as needed (skipping empty ones, which can't look
    /// like the end); empty at the end of the stream; `None` if it must wait
    /// for more ciphertext.
    fn next(&mut self, max: usize) -> io::Result<Option<Vec<u8>>> {
        if self.failed {
            return Err(not_authentic());
        }
        loop {
            if let Some(bytes) = self.take(max) {
                return Ok(Some(bytes));
            }
            let Some(len) = self.whole_message() else {
                if !self.ended {
                    return Ok(None);
                }
                if self.ciphertext.is_empty() {
                    return Ok(Some(Vec::new()));
                }
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "Noise: the stream ended partway through a message"));
            };
            let mut message: Vec<u8> = self.ciphertext.drain(..2 + len).skip(2).collect();
            let nonce = self.cipher.next_nonce()?;
            let Ok(plain) = self.cipher.key.open_in_place(nonce, aead::Aad::empty(), &mut message) else {
                self.failed = true;
                return Err(not_authentic());
            };
            self.plain = plain.to_vec();
            self.taken = 0;
        }
    }
}

pub struct NoiseStream {
    wire: Wire,
    read_lock: Lock,
    write_lock: Lock,
    send: Mutex<CipherState>,
    receive: Mutex<Received>,
    /// `Select`s waiting on this stream for something the socket won't show:
    /// another reader releasing the read lock, perhaps leaving plaintext or
    /// whole messages behind. Woken at lock releases (see [`Reading`]).
    watchers: Mutex<Waiters>,
}

/// The held read lock; releasing it wakes the stream's `Select` watchers.
///
/// If the holder only found the socket empty with nothing buffered
/// ([`Reading::idle`]), it wakes just the watchers that started waiting during the hold. Those tried to poll
/// while it was held, so they never looked at the socket themselves, and
/// data may have arrived (its edge event going to nobody) before they
/// started waiting. The earlier watchers saw the socket empty themselves,
/// and wait on it. (Waking those too made two `Select`s on one idle stream
/// wake each other in a loop.)
struct Reading<'a> {
    guard: Option<LockGuard<'a>>,
    watchers: &'a Mutex<Waiters>,
    /// The first watcher id given out during the hold.
    first: u64,
    idle: bool,
}

impl Reading<'_> {
    /// Nothing for the earlier watchers came of this hold: the socket would
    /// block and nothing whole is buffered.
    fn idle(&mut self) {
        self.idle = true;
    }
}

impl Drop for Reading<'_> {
    fn drop(&mut self) {
        // Release first: a watcher woken before it would find it still held.
        drop(self.guard.take());
        let mut watchers = lock(self.watchers);
        if self.idle {
            watchers.wake_from(self.first);
        } else {
            watchers.wake_all();
        }
    }
}

/// Whether a `Select` must wait for a Noise stream (see [`NoiseStream::watch`]).
pub enum Watch {
    /// A poll would find something now.
    Ready,
    /// Registered under this id (remove with [`NoiseStream::unwatch`]).
    Waiting(u64),
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
                ciphertext: Vec::new(),
                ended: false,
                failed: false,
            }),
            watchers: Mutex::new(Waiters::new()),
        })
    }

    // The first watcher id is read before the lock is taken: a watcher
    // arriving in between is woken too, which is harmless; one arriving
    // once the lock is held mustn't be missed.

    fn lock_read(&self) -> Reading<'_> {
        let first = lock(&self.watchers).next_id();
        Reading { guard: Some(self.read_lock.lock()), watchers: &self.watchers, first, idle: false }
    }

    fn try_lock_read(&self) -> Option<Reading<'_>> {
        let first = lock(&self.watchers).next_id();
        self.read_lock
            .try_lock()
            .map(|guard| Reading { guard: Some(guard), watchers: &self.watchers, first, idle: false })
    }

    /// Read more ciphertext, waiting until `deadline` at the latest (as well
    /// as the read timeout). Holding the read lock.
    fn receive_more(&self, deadline: Option<Instant>) -> io::Result<()> {
        let mut got = Vec::new();
        let n = self.wire.read_by(deadline, &mut got)?;
        let mut received = lock(&self.receive);
        received.ciphertext.extend_from_slice(&got);
        received.ended |= n == 0;
        Ok(())
    }

    pub fn wire(&self) -> &Wire {
        &self.wire
    }

    /// Up to `max` bytes of plaintext, reading and decrypting the next
    /// message if none is left over; empty once the stream has ended.
    ///
    /// A clean end at a message boundary can't be told from one an attacker
    /// forced by cutting the connection: Noise has no closing message, so a
    /// protocol that needs to know it got everything must say so itself.
    pub fn read(&self, max: usize) -> io::Result<Vec<u8>> {
        let _r = self.lock_read();
        loop {
            if let Some(bytes) = lock(&self.receive).next(max)? {
                return Ok(bytes);
            }
            self.receive_more(None)?;
        }
    }

    /// `read`, without waiting, for `Select`: `None` if it would have to
    /// (nothing whole has arrived, or another task is reading).
    pub fn try_read(&self, max: usize) -> io::Result<Option<Vec<u8>>> {
        let Some(mut reading) = self.try_lock_read() else { return Ok(None) };
        loop {
            if let Some(bytes) = lock(&self.receive).next(max)? {
                return Ok(Some(bytes));
            }
            let mut got = Vec::new();
            let Some(n) = self.wire.read_now(&mut got)? else {
                reading.idle();
                return Ok(None);
            };
            let mut received = lock(&self.receive);
            received.ciphertext.extend_from_slice(&got);
            received.ended |= n == 0;
        }
    }

    /// Wait until a `try_read` may find something (plaintext, the end, or an
    /// error), until `by` at the latest as well as the read timeout, for a
    /// copy. Returns at once if it already would.
    pub fn fill_by(&self, by: Option<Instant>) -> io::Result<()> {
        let _r = self.lock_read();
        loop {
            if lock(&self.receive).readable() {
                return Ok(());
            }
            self.receive_more(by)?;
        }
    }

    /// For a `Select` whose poll of this stream found nothing: register
    /// `waker` for read lock releases, then check (after registering, so a
    /// release in between isn't missed) whether a poll would now find
    /// something the socket won't announce: something buffered, or data on
    /// the socket that this `Select`'s poll didn't get to read (another task
    /// held the lock then) and whose event may have gone to nobody.
    pub fn watch(&self, waker: &TaskWaker) -> Watch {
        let id = lock(&self.watchers).add_waker(waker.clone());
        // Held: its release wakes this watcher, which arrived during the hold.
        if self.read_lock.is_locked() {
            return Watch::Waiting(id);
        }
        if lock(&self.receive).readable() || crate::sockets::readable_now(self.wire.io_parts().0) {
            self.unwatch(id);
            return Watch::Ready;
        }
        Watch::Waiting(id)
    }

    pub fn unwatch(&self, id: u64) {
        lock(&self.watchers).remove(id);
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
