//! Name resolution with a deadline.
//!
//! The system resolver (getaddrinfo, behind `ToSocketAddrs`) blocks and can't
//! be cancelled or given a timeout, so every lookup runs on a helper thread
//! (`sched::blocking`) while the task waits, until the deadline if there is
//! one; an abandoned lookup finishes in the background whenever the resolver
//! gives up. Helper threads are capped (`MAX_BLOCKING_THREADS`), abandoned
//! lookups included, so an unresponsive DNS server, or hostnames chosen by
//! an attacker, can't pile up threads: past the cap, lookups wait for a
//! slot, and ones with a deadline fail with `TimedOut` if none frees up in
//! time.
//!
//! IP-address literals never reach the resolver.

use std::io;
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::time::Instant;

/// Resolve `target` ("host:port", or `(host, port)`), giving up with
/// `TimedOut` at `deadline`.
fn lookup<T>(target: T, deadline: Option<Instant>) -> io::Result<Vec<SocketAddr>>
where
    T: ToSocketAddrs + Send + 'static,
{
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return Err(io::Error::new(io::ErrorKind::TimedOut, "name lookup timed out"));
    }
    let answer = crate::sched::blocking(deadline, move || target.to_socket_addrs().map(|addrs| addrs.collect()))?;
    answer.unwrap_or_else(|| Err(io::Error::new(io::ErrorKind::TimedOut, "name lookup timed out")))
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
