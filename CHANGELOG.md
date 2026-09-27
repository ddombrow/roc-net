# Changelog

Releases are published on
[GitLab](https://gitlab.com/ddombrow/roc-net/-/releases). Each one names the
Roc nightly it's built for; apps must use that nightly.

## 0.1.0

The first release. Built for Roc `nightly-2026-09-24-f45bfbe`, with hosts for
macOS (arm64, x86-64) and static Linux (musl: arm64, x86-64).

- **TCP, UDP and Unix sockets.** Streams share one set of methods (`read!`,
  `read_into!`, `read_append!`, `write!`, `shutdown!`, timeouts), so code
  written against them works with any stream type. Typed errors (`IOErr`).
- **TLS** (rustls with AWS-LC): clients, servers, and STARTTLS, with the same
  stream methods.
- **Tasks and channels.** `Task.spawn!` runs a task concurrently: a coroutine
  on a small pool of worker threads, with work stealing. Bounded channels
  pass values between tasks.
- **Framing and bytes.** Line- and length-prefixed framing with limits and
  timeouts; `Bytes` encoders and decoders.
- **DNS, time, randomness.** `Dns.resolve!`, `Time` (monotonic instants,
  sleeping), `Random` (secure).
- **Resource safety.** Sockets close automatically when Roc drops them.
  Every table, queue, read and task count has a limit, and every blocking
  operation can time out; servers get idle and write timeouts by default,
  TLS handshakes a deadline.
- **Examples**: echo servers and clients (TCP, UDP, Unix), a proxy, a chat
  server, a line-protocol server, an HTTPS GET, a DNS client and `tcp_ping`.

See the README's "Known limitations".
