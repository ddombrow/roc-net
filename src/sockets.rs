//! Host-side table of open sockets. Roc only ever sees the `u64` handles.

use std::collections::BTreeMap;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::Mutex;

pub enum Socket {
    Listener(TcpListener),
    Stream(TcpStream),
}

struct Table {
    next_id: u64,
    open: BTreeMap<u64, Socket>,
}

static TABLE: Mutex<Table> = Mutex::new(Table {
    next_id: 1,
    open: BTreeMap::new(),
});

fn table() -> std::sync::MutexGuard<'static, Table> {
    TABLE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn insert(socket: Socket) -> u64 {
    let mut table = table();
    let id = table.next_id;
    table.next_id += 1;
    table.open.insert(id, socket);
    id
}

pub fn remove(id: u64) {
    // Other tasks may hold clones of a stream (e.g. one blocked in read), so
    // shut it down explicitly; that wakes them with EOF instead of leaving them
    // blocked on a socket that stays open until every clone is dropped.
    if let Some(Socket::Stream(stream)) = table().open.remove(&id) {
        let _ = stream.shutdown(Shutdown::Both);
    }
}

/// A clone of the listener, so callers can block on it without holding the lock.
pub fn listener(id: u64) -> Result<TcpListener, String> {
    match table().open.get(&id) {
        Some(Socket::Listener(listener)) => listener.try_clone().map_err(|err| err.to_string()),
        Some(Socket::Stream(_)) => Err(format!("handle {id} is a stream, not a listener")),
        None => Err(format!("handle {id} is closed or unknown")),
    }
}

/// A clone of the stream, so callers can block on it without holding the lock.
pub fn stream(id: u64) -> Result<TcpStream, String> {
    match table().open.get(&id) {
        Some(Socket::Stream(stream)) => stream.try_clone().map_err(|err| err.to_string()),
        Some(Socket::Listener(_)) => Err(format!("handle {id} is a listener, not a stream")),
        None => Err(format!("handle {id} is closed or unknown")),
    }
}
