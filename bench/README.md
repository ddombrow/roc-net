# Benchmarks

`just bench --label "what changed"` measures roc-net's echo server against two
Rust echo servers and appends the results to `results.csv`, tagged with the
time, git commit, and label. `just bench-history` shows roc-net's numbers
across runs.

## Servers

| Name | What it is | Comparing roc-net against it measures |
| --- | --- | --- |
| `roc` | `roc-echo/main.roc`: one `Task.spawn!` per connection | – |
| `threads` | Blocking std sockets, one OS thread per connection | roc-net's own overhead (same architecture) |
| `tokio` | Tokio multi-threaded runtime, one task per connection | the cost of roc-net's architecture |

All three read up to 4 KiB and echo it back, and silently end a connection on
an error.

## Scenarios

| Scenario | Load | Headline metrics |
| --- | --- | --- |
| `pingpong_1`, `pingpong_64` | 1 or 64 connections, each sending 64 bytes and waiting for the echo | requests/s, p50/p99 latency |
| `bulk_1`, `bulk_16` | 1 or 16 connections streaming 64 KiB writes | MiB/s |
| `churn_32` | 32 workers connecting, echoing 16 bytes, and disconnecting | connections/s |
| `hold_10000` | Open up to 10,000 connections and keep them open | how many were served, and whether the server survived |

Every scenario gets a freshly started server. `cpu_us_per_op` is the server's
total CPU time (user + system) divided by requests, MiB, or connections.

## Reading the results

- **Use `cpu_us_per_op` to compare efficiency.** The load generator runs on
  the same machine and, with the kernel's loopback path, limits throughput
  before the servers do: all three servers reach about the same requests/s.
  CPU per operation still shows what each server spends.
- **Noise:** between identical runs, `cpu_us_per_op` varies by about 3% for
  pingpong and churn and up to 10% for `bulk_1`. `bulk_16` throughput varies
  by as much as 25%, and p99 latency with 64 connections occasionally spikes,
  so check a surprising number by rerunning that scenario before believing it.
- Results depend on the machine; compare runs from the same one.
- The load generator resets connections instead of closing them, because
  closed connections sit in TIME_WAIT and tens of thousands of them exhaust
  the ephemeral port range. The runner warns if TIME_WAIT sockets pile up.

## Baseline (2026-09-26, commit 23568de, Apple M4 Pro, 12 cores)

| Scenario | roc | threads | tokio |
| --- | ---: | ---: | ---: |
| pingpong_1 req/s | 68k | 68k | 65k |
| pingpong_1 CPU µs/request | 4.8 | 4.5 | 5.1 |
| pingpong_64 req/s | 163k | 164k | 165k |
| pingpong_64 CPU µs/request | 12.0 | 11.3 | 17.4 |
| bulk_1 MiB/s | 1,795 | 1,940 | 1,207 |
| bulk_1 CPU µs/MiB | 560 | 521 | 1,206 |
| churn_32 conns/s | 38k | 35k | 39k |
| churn_32 CPU µs/connection | 31.6 | 36.1 | 26.5 |
| hold_5000 connections served | **1,024 (server exited)** | 5,000 | 5,000 |

Averages of the two `baseline` runs in `results.csv`. Those runs used
`hold_5000`; later runs use `hold_10000`.

## Changes

| Run label | Change | Effect |
| --- | --- | --- |
| `shed at limits` | At the task limit, drop the connection instead of exiting; limits configurable, default 10,000 tasks | roc holds 6,143 connections (the macOS thread limit, same as `threads`) and survives, instead of exiting at 1,024. Other scenarios unchanged within noise. |
| `m4: shared socket functions` | One set of hosted functions for TCP, Unix, and UDP sockets | No change within noise. |
| `channels (extra dealloc check)` | Every Roc deallocation also checks the channel heap | No change within noise. |
| `boxed tls + read into roc list` | TLS socket state boxed; reads straight into the Roc list | Startup memory 22.8 MB to 3.7 MB (every socket-heap slot was sized for TLS state). Reading into the list: within noise, reverted. |
| `reuse task threads` | Finished task threads wait up to 10 s for the next task (at most 64 idle) | churn CPU/connection 34 to 21.7 µs (-36%); thread creation was ~40% of active time. |
| `thread reuse + per-thread read buffer` | Reads use a reused per-thread buffer instead of a fresh zeroed one | macOS: pingpong_64 11.8 to 11.3 µs. Linux (`just bench-linux`): musl pingpong_64 4.06 to 3.10 µs, bulk_16 724 to 430 µs/MiB; musl now matches glibc. |
| `read_into! (buffer reuse)` | New `read_into!`/`read_append!` put what arrived into a buffer the caller passes back, reusing its allocation; the benchmark server uses `read_into!` | macOS: pingpong_1 4.74 to 4.55 µs; bulk_1 ~575 to ~505 µs/MiB (at the edge of its noise). Linux: pingpong_64 ~3.1 to ~2.9 µs, glibc bulk_16 441 to 405-412 µs/MiB; musl bulk_16 430 to 437-452 (no gain, within noise) |
| `coroutines` | Tasks are coroutines on one worker thread per CPU (`src/sched.rs`), placed round-robin | hold_10000: 10,000 connections (was 6,143, the macOS thread limit). CPU per op up: pingpong_64 11.3 to 13.7 µs, churn 21.7 to 32.4 µs; almost all of it waking sleeping workers, not scheduler code. |
| `coroutines: local-first placement` | New tasks stay on the spawning worker unless it's busy or over its share | macOS: pingpong_64 10.4 µs, bulk_16 825 µs/MiB at 1,471 MiB/s, churn 15.1 µs: better than the thread server (11.2, 889, 35.3). Linux: churn 12.8 µs (Rust threads 56-88), but pingpong_64 3.4 µs vs 2.5 and bulk_16 440-490 µs/MiB vs 296, at half the Rust server's throughput. |

## Linux

`just bench-linux` runs the same kind of load in an arm64 Linux container
against roc-net's musl and glibc builds and the plain-Rust server (also both
ways). It found what the macOS runs couldn't: allocating and zeroing a read
buffer per read cost musl builds 30-60% more CPU under concurrency (musl's
memset is slower than glibc's). mimalloc was tried first and made no
difference; the plain-Rust server showing no musl/glibc gap pointed at
roc-net's read path instead. Latest (6-CPU Colima VM):

| CPU per op (throughput) | roc (coroutines) | Rust threads | Tokio |
| --- | ---: | ---: | ---: |
| pingpong_1 | 11.5-11.7 µs | 9.9-10.0 µs | 10.9-11.2 µs |
| pingpong_64 | 3.4-4.9 µs (490-850k/s) | 2.5 µs (1.18M/s) | 5.2-5.5 µs (330-390k/s) |
| bulk_16 | 444-482 µs/MiB (4.2-6.8 GiB/s) | 303-308 µs/MiB (13.2-13.5 GiB/s) | 367-371 µs/MiB (10.5 GiB/s) |
| churn_32 | 13.0-13.6 µs | 57-92 µs | 15.8-15.9 µs |

(Ranges cover the musl and glibc builds; roc's pingpong_64 also varies run
to run with how connections land on workers.) Against Tokio, the reference
async runtime, roc-net's coroutines do better on request-response and short
connections and worse on bulk transfer, where Tokio's work stealing spreads
busy connections across CPUs; the thread-per-connection server beats both on
busy connections in this setup.

This VM is where coroutines look worst: the load generator shares the 6
CPUs, waking it on another CPU is expensive under virtualization, and
connections that arrive in a burst can crowd onto one worker, since tasks
never move. The thread server pays for a new thread per connection, which
is why both async servers win churn.

With `read_into!` there's no allocation per read, but still one copy (from
the host's per-thread buffer into the Roc list, since Rust can't soundly
read into memory that hasn't been initialized); the Rust servers read in
place. The rest of the gap is per-call handle lookups, refcounting, and the
Roc code itself.
