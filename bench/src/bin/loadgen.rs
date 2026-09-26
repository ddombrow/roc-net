//! Load generator for echo servers. Prints one JSON object of metrics.
//!
//! loadgen ADDRESS SCENARIO [OPTIONS]
//!   pingpong  --conns N --size BYTES --secs S   request/response rate and latency
//!   bulk      --conns N --secs S                streaming throughput (64 KiB writes)
//!   churn     --conns N --secs S                new connections per second
//!   hold      --conns N                         how many connections can be open at once

use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

struct Opts {
    conns: usize,
    size: usize,
    secs: f64,
}

fn parse_opts(args: &[String]) -> Opts {
    let mut opts = Opts { conns: 1, size: 64, secs: 3.0 };
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let value = it.next().expect("missing option value");
        match flag.as_str() {
            "--conns" => opts.conns = value.parse().unwrap(),
            "--size" => opts.size = value.parse().unwrap(),
            "--secs" => opts.secs = value.parse().unwrap(),
            other => panic!("unknown option {other}"),
        }
    }
    opts
}

fn connect(address: &str) -> std::io::Result<TcpStream> {
    let stream = TcpStream::connect(address)?;
    stream.set_nodelay(true)?;
    Ok(stream)
}

/// Close with RST instead of FIN so the client side leaves no TIME_WAIT
/// entry; otherwise the churn test runs out of ephemeral ports.
fn close_abortively(stream: TcpStream) {
    use std::os::fd::AsRawFd;
    let linger = libc::linger { l_onoff: 1, l_linger: 0 };
    unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_LINGER,
            &linger as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::linger>() as libc::socklen_t,
        );
    }
    drop(stream);
}

fn read_exact_or_fail(stream: &mut TcpStream, buf: &mut [u8]) -> bool {
    stream.read_exact(buf).is_ok()
}

fn percentile(sorted: &[u32], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let index = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[index] as f64
}

fn pingpong(address: &str, opts: &Opts) -> String {
    let deadline_after = Duration::from_secs_f64(opts.secs);
    let barrier = Arc::new(Barrier::new(opts.conns));
    let workers: Vec<_> = (0..opts.conns)
        .map(|_| {
            let address = address.to_string();
            let barrier = barrier.clone();
            let size = opts.size;
            thread::spawn(move || {
                let mut latencies = Vec::with_capacity(1 << 16);
                let mut errors = 0u64;
                let Ok(mut stream) = connect(&address) else {
                    barrier.wait();
                    return (latencies, 1);
                };
                let request = vec![b'x'; size];
                let mut reply = vec![0u8; size];
                barrier.wait();
                let start = Instant::now();
                while start.elapsed() < deadline_after {
                    let sent = Instant::now();
                    if stream.write_all(&request).is_err() || !read_exact_or_fail(&mut stream, &mut reply) {
                        errors += 1;
                        break;
                    }
                    latencies.push(sent.elapsed().as_micros() as u32);
                }
                (latencies, errors)
            })
        })
        .collect();

    let mut latencies = Vec::new();
    let mut errors = 0;
    for worker in workers {
        let (mut l, e) = worker.join().unwrap();
        latencies.append(&mut l);
        errors += e;
    }
    latencies.sort_unstable();
    format!(
        r#"{{"ops": {}, "requests_per_sec": {:.0}, "p50_us": {}, "p99_us": {}, "errors": {}}}"#,
        latencies.len(),
        latencies.len() as f64 / opts.secs,
        percentile(&latencies, 0.50),
        percentile(&latencies, 0.99),
        errors
    )
}

fn bulk(address: &str, opts: &Opts) -> String {
    let received = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let mut errors = 0u64;
    let mut handles = Vec::new();
    for _ in 0..opts.conns {
        let Ok(stream) = connect(address) else {
            errors += 1;
            continue;
        };
        let mut writer = stream.try_clone().unwrap();
        let stop_writer = stop.clone();
        handles.push(thread::spawn(move || {
            let chunk = vec![b'x'; 64 * 1024];
            while !stop_writer.load(Ordering::Relaxed) {
                if writer.write_all(&chunk).is_err() {
                    break;
                }
            }
            let _ = writer.shutdown(Shutdown::Write);
        }));
        let mut reader = stream;
        let received = received.clone();
        handles.push(thread::spawn(move || {
            let mut buf = vec![0u8; 256 * 1024];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                received.fetch_add(n as u64, Ordering::Relaxed);
            }
        }));
    }
    // Measure only the steady-state window, not connection setup or drain.
    thread::sleep(Duration::from_millis(200));
    let before = received.load(Ordering::Relaxed);
    let start = Instant::now();
    thread::sleep(Duration::from_secs_f64(opts.secs));
    let bytes = received.load(Ordering::Relaxed) - before;
    let elapsed = start.elapsed().as_secs_f64();
    stop.store(true, Ordering::Relaxed);
    for handle in handles {
        let _ = handle.join();
    }
    // ops = MiB echoed over the whole run, for CPU cost per MiB.
    let total_mib = received.load(Ordering::Relaxed) as f64 / (1024.0 * 1024.0);
    format!(
        r#"{{"ops": {:.1}, "mib_per_sec": {:.1}, "errors": {}}}"#,
        total_mib,
        bytes as f64 / elapsed / (1024.0 * 1024.0),
        errors
    )
}

fn churn(address: &str, opts: &Opts) -> String {
    let deadline_after = Duration::from_secs_f64(opts.secs);
    let workers: Vec<_> = (0..opts.conns)
        .map(|_| {
            let address = address.to_string();
            thread::spawn(move || {
                let (mut ok, mut errors) = (0u64, 0u64);
                let mut reply = [0u8; 16];
                let start = Instant::now();
                while start.elapsed() < deadline_after {
                    let result = connect(&address).and_then(|mut stream| {
                        stream.write_all(&[b'x'; 16])?;
                        stream.read_exact(&mut reply)?;
                        // Reset without ever sending FIN. The side that sends
                        // FIN first keeps a TIME_WAIT entry for ~15s, and
                        // thousands of those exhaust the ephemeral ports.
                        close_abortively(stream);
                        Ok(())
                    });
                    match result {
                        Ok(()) => ok += 1,
                        Err(_) => errors += 1,
                    }
                }
                (ok, errors)
            })
        })
        .collect();
    let (mut ok, mut errors) = (0, 0);
    for worker in workers {
        let (o, e) = worker.join().unwrap();
        ok += o;
        errors += e;
    }
    format!(
        r#"{{"ops": {}, "conns_per_sec": {:.0}, "errors": {}}}"#,
        ok,
        ok as f64 / opts.secs,
        errors
    )
}

fn hold(address: &str, opts: &Opts) -> String {
    let mut open = Vec::with_capacity(opts.conns);
    let mut failed_at = None;
    for i in 0..opts.conns {
        let ok = connect(address).and_then(|mut stream| {
            stream.set_read_timeout(Some(Duration::from_secs(2)))?;
            stream.write_all(b"x")?;
            let mut reply = [0u8; 1];
            stream.read_exact(&mut reply)?;
            Ok(stream)
        });
        match ok {
            Ok(stream) => open.push(stream),
            Err(_) => {
                failed_at = Some(i);
                break;
            }
        }
    }
    let max_open = open.len();
    for stream in open {
        close_abortively(stream);
    }
    format!(
        r#"{{"max_open_conns": {}, "hit_limit": {}}}"#,
        max_open,
        failed_at.is_some()
    )
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (address, scenario) = (&args[1], args[2].as_str());
    let opts = parse_opts(&args[3..]);
    let result = match scenario {
        "pingpong" => pingpong(address, &opts),
        "bulk" => bulk(address, &opts),
        "churn" => churn(address, &opts),
        "hold" => hold(address, &opts),
        other => panic!("unknown scenario {other}"),
    };
    println!("{result}");
}
