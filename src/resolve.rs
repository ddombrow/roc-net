//! Name resolution with a deadline.
//!
//! The system resolver (getaddrinfo, behind `ToSocketAddrs`) blocks and can't
//! be cancelled or given a timeout. With a deadline, the lookup runs on a
//! helper thread and the caller waits for it only until the deadline; an
//! abandoned lookup finishes in the background whenever the resolver gives
//! up. At most `MAX_PENDING` lookups can be in flight, so an unresponsive DNS
//! server can't pile up threads: past that, lookups with a deadline fail
//! with `TimedOut` at once.
//!
//! IP-address literals never reach the resolver.

use std::io;
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::Instant;

const MAX_PENDING: usize = 64;

static PENDING: AtomicUsize = AtomicUsize::new(0);

/// Releases a pending-lookup slot when the lookup ends, even by unwinding.
struct Slot;

impl Drop for Slot {
    fn drop(&mut self) {
        PENDING.fetch_sub(1, Ordering::AcqRel);
    }
}

fn timed_out(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, what.to_string())
}

/// Resolve `target` ("host:port", or `(host, port)`), giving up with
/// `TimedOut` at `deadline`.
fn lookup<T>(target: T, deadline: Option<Instant>) -> io::Result<Vec<SocketAddr>>
where
    T: ToSocketAddrs + Send + 'static,
{
    let Some(deadline) = deadline else {
        return Ok(target.to_socket_addrs()?.collect());
    };
    if Instant::now() >= deadline {
        return Err(timed_out("name lookup timed out"));
    }
    let claimed = PENDING.fetch_update(Ordering::AcqRel, Ordering::Acquire, |pending| {
        (pending < MAX_PENDING).then_some(pending + 1)
    });
    if claimed.is_err() {
        return Err(timed_out("name lookup not started: too many slow lookups in progress"));
    }
    let slot = Slot;
    let (answer, answered) = mpsc::channel();
    let spawned = std::thread::Builder::new().name("roc-net-resolve".into()).spawn(move || {
        let _slot = slot;
        let _ = answer.send(target.to_socket_addrs().map(|addrs| addrs.collect()));
    });
    if let Err(err) = spawned {
        return Err(err);
    }
    match answered.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        Ok(result) => result,
        Err(_) => Err(timed_out("name lookup timed out")),
    }
}

/// The addresses to try for `address` ("host:port" or "[v6]:port").
pub fn socket_addrs(address: &str, deadline: Option<Instant>) -> io::Result<Vec<SocketAddr>> {
    if let Ok(addr) = address.parse::<SocketAddr>() {
        return Ok(vec![addr]);
    }
    lookup(address.to_string(), deadline)
}

/// The IP addresses for a host name.
pub fn host_ips(name: &str, deadline: Option<Instant>) -> io::Result<Vec<IpAddr>> {
    if let Ok(ip) = name.parse::<IpAddr>() {
        return Ok(vec![ip]);
    }
    Ok(lookup((name.to_string(), 0u16), deadline)?.into_iter().map(|addr| addr.ip()).collect())
}
