# Changelog

Releases are published on
[GitLab](https://gitlab.com/ddombrow/roc-net/-/releases). Each one names the
Roc nightly it's built for; apps must use that nightly.

## 0.2.1

Built for Roc `nightly-2026-09-24-f45bfbe`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Fixes and additions from building a TLS-terminating proxy.

- **Fixed**: a server-side TLS stream could deadlock when one task read from
  it while another wrote before the handshake had finished, such as a proxy
  in front of a server that speaks first (SMTP, SSH). The writer ended up
  waiting behind the reader, which was waiting for the client, which was
  waiting for the greeting. The handshake now has its own lock, so once it's
  done, a writer never queues behind a reader. Code that worked around it by
  writing an empty message first (`stream.write!([])`) can drop that.
- **`Tls.Stream.handshake!`**: finish a server stream's handshake at a point
  of your choosing, such as right after `accept!` and before sharing the
  stream between tasks, so a failed handshake is reported there rather than
  by whichever task used the stream first.
- **Fixed**: a certificate, key or CA file that couldn't be loaded failed
  with a bare `TlsErr(InvalidInput)`. It now fails with
  `TlsErr(Other("server.pem: No such file or directory (os error 2)"))`,
  naming the file and the reason, and so does a malformed PEM or a key that
  doesn't match the certificate. An invalid server name says why too.
- **Fixed**: `shutdown!` on a stream whose peer had already closed failed
  with `NotConnected` on macOS, so proxies logged clean sessions as errors.
  It now succeeds (TCP, Unix and TLS).
- **Docs**: what happens when a task in a `Task.scope!` fails (the others
  keep running; only the body's result cancels them), with a pattern for
  stopping them all when the first one ends; when a TLS-terminating proxy can
  use `ignore_unexpected_eof!`.

## 0.2.0

Built for Roc `nightly-2026-09-24-f45bfbe`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Concurrency: tasks can wait for whichever of several things happens first,
and have lifetimes.

- **`Select`**: wait for the first of several arms (a stream read, a
  connection, a `Framing` line or frame, a channel value or room, a timeout),
  each mapped to a value of your own type. Only the winning arm consumes
  anything, and ready arms take turns.
- **Task handles**: `Task.spawn!` returns a `Handle` with `join!` (the task's
  result, as often as needed) and `cancel!`. Cancelling is cooperative: waits
  end with a new `Cancelled` error (`IOErr.Cancelled` for sockets), which `?`
  passes up. `Task.is_cancelled!` and `Task.yield!` for long computations.
- **`Task.scope!`**: tasks that can't outlive a block. It waits for them, and
  cancels them first if the block fails.
- **Streams and channels** gain `try_read!`, `try_accept!` and `socket` (for
  `Select`); channel sends and receives can fail with `Cancelled`.
- **Fixed**: a task waiting on a socket watched by another worker thread
  could miss its wake-up and wait forever (a TLS reader and writer on
  different workers).
- **Breaking**: `Task.spawn!` returns `Try(Handle(ok, err),
  [TaskLimitReached])` instead of `Try({}, ...)`: write `_ = Task.spawn!(...)?`
  where the result isn't used. A task's error type includes `Cancelled`.
  `Time.sleep!` returns `Try({}, [Cancelled])` (write `Time.sleep!(...)?`), so
  a cancelled task stops at a sleep like at any other wait.
- **Examples**: `chat_server` uses one task per client with `Select`
  (optional silence limit: `chat_server ADDRESS SECONDS`); `tcp_proxy` runs
  both directions in a scope and passes a half-close through instead of
  closing the connection; new `first_to_answer` connects to several addresses
  at once and cancels the losers.

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
