//! Baseline with roc-net's architecture: blocking sockets, one OS thread per
//! connection, 4 KiB reads. Differences from roc-net measure platform overhead.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

fn echo(mut stream: TcpStream) {
    let mut buf = [0u8; 4096];
    loop {
        match stream.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => {
                if stream.write_all(&buf[..n]).is_err() {
                    return;
                }
            }
        }
    }
}

fn main() {
    let address = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:8080".into());
    let listener = TcpListener::bind(&address).expect("bind");
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                std::thread::spawn(move || echo(stream));
            }
            Err(err) => eprintln!("accept: {err}"),
        }
    }
}
