//! Baseline with an async architecture: Tokio's multi-threaded runtime, one
//! task per connection, 4 KiB reads.

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() {
    let address = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:8080".into());
    let listener = TcpListener::bind(&address).await.expect("bind");
    loop {
        let Ok((mut stream, _)) = listener.accept().await else { continue };
        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                match stream.read(&mut buf).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => {
                        if stream.write_all(&buf[..n]).await.is_err() {
                            return;
                        }
                    }
                }
            }
        });
    }
}
