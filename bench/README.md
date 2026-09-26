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
| `hold_5000` | Open up to 5,000 connections and keep them open | how many were served, and whether the server survived |

Every scenario gets a freshly started server. `cpu_us_per_op` is the server's
total CPU time (user + system) divided by requests, MiB, or connections.

## Reading the results

- **Use `cpu_us_per_op` to compare efficiency.** The load generator runs on
  the same machine and, with the kernel's loopback path, limits throughput
  before the servers do: all three servers reach about the same requests/s.
  CPU per operation still shows what each server spends.
- **Noise:** between identical runs, `cpu_us_per_op` varies by about 3% for
  pingpong and churn and up to 10% for `bulk_1`. `bulk_16` varies by about
  15% in both throughput and CPU, so treat small changes there as noise.
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

Averages of the two `baseline` runs in `results.csv`.
