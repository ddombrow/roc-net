# Changelog

Releases are published on
[GitLab](https://gitlab.com/ddombrow/roc-net/-/releases). Each one names the
Roc nightly it's built for; apps must use that nightly.

## 0.3.2

Built for Roc `nightly-2026-09-24-f45bfbe`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Added:

- **`Log`**: structured log lines for servers. `Log.info!("session ended",
  [Str("peer", peer), U64("up", n)])` writes
  `2026-09-30T12:34:56.789Z INFO session ended peer=... up=120 task=17` to
  stderr, with the wall-clock time, the level and the task that logged it;
  or one JSON object per line with `ROC_NET_LOG_FORMAT=json`. `ROC_NET_LOG`
  sets the level (`debug`, `info`, `warn`, `error`, `off`), and
  `Log.enabled!` lets code skip building fields that wouldn't be written.
  - **It never waits**: a thread of its own writes the lines, so a slow or
    stalled stderr (a full pipe, a paused terminal) can't stall a server, as
    `Stderr.line!` can. Waiting lines are capped at about 1 MiB
    (`ROC_NET_LOG_BUFFER_KIB`); past that the oldest are dropped, and a
    warning counts them. Very long strings and lines are cut short, and
    marked.
  - The platform's own messages go through it: a detached task failing,
    `main!` returning an error (`main! failed`), and warnings such as running
    out of file descriptors. What's queued gets up to a second to be
    written when the program exits.
- **`Time.utc_now!`** and `Time.Utc`: the wall clock, with
  `to_rfc3339()` (`2026-09-30T12:34:56.789Z`) and conversions to and from
  Unix times in seconds, milliseconds and nanoseconds.

Changed:

- `main!` returning an error is reported as a log line
  (`... ERROR main! failed error=...`) instead of `ERROR: ...`, and a detached
  task failing as `... ERROR task failed error=...` instead of
  `task failed: ...`.

## 0.3.1

Built for Roc `nightly-2026-09-24-f45bfbe`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Added:

- **`Stream.copy_to!(from, to, limit)`**: the one-way counterpart of
  `copy_both!`, for streaming one direction while handling the other in
  Roc, or sending a message's body after its header. `UntilEnd` copies
  until `from` ends; `Exactly(n)` copies exactly `n` bytes and never reads
  past them, so the connection is ready for the next message (for TLS, the
  rest of a record stays in the stream). It shuts down and aborts nothing:
  what comes next is the caller's choice. Errors are
  `CopyToErr({ failed: Read(...) | Write(...) | MessageTimedOut, copied })`,
  a tag of its own, so code using `?` on both `copy_to!` and `copy_both!`
  still typechecks. `copied` counts the bytes `to` accepted; its peer may
  have received fewer. Same copying as `copy_both!` (the two share one
  loop): no Roc lists, no buffer while idle, and `splice` on Linux between
  plain sockets.
- **`Framing.Reader.copy_to!(to, limit)`**: the same, starting with the
  bytes the reader has already buffered, and returning the reader with
  whatever came after the limit (the start of the next message) still
  buffered. Use it instead of `Stream.copy_to!` once a reader has read from
  the stream. With `Exactly(n)` the bytes are one message, so the reader's
  message timeout bounds the whole copy (`MessageTimedOut`), as it bounds
  `read_exactly!`: a peer can't keep a connection busy by trickling a body.

Fixed:

- `copy_both!`'s docs said its byte counts were what got through; they're
  what each side accepted, and the peers may have received fewer.

## 0.3.0

Built for Roc `nightly-2026-09-24-f45bfbe`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Proxy features.

- **SNI**: `Tls.ServerConfig.with_cert_for(name, { cert_file, key_file })`
  presents a certificate per host name on one listener (`*.example.com`
  wildcards covering one label, exact names first); the certificate from
  `server_config` is for clients asking for any other name, or none.
  `Tls.Stream.server_name!` returns the name a client asked for, as
  `Name(...)` (lower-cased, no trailing dot, so it agrees with certificate
  selection) or `NoName`, for routing by host name.
- **ALPN**: `with_alpn([...])` on both `ClientConfig` and `ServerConfig`, and
  `Tls.Stream.alpn_protocol!` for the protocol agreed.
- **`Stream.copy_both!(a, b)`**: the two directions of a proxy, copied by the
  platform between any two streams (TCP, TLS, Unix) without each chunk
  becoming a Roc list. It passes half-closes on. On the first error it
  aborts both streams, so a backend that fails mid-response never reaches
  the client as a clean (and truncated) end (a stream whose incoming data
  had already ended cleanly is left alone, so a slow client still gets a
  finished response), and reports where it happened and how far each
  direction got:
  `CopyErr({ failed: ReadB(ConnectionReset), a_to_b, b_to_a })`. Cancelling
  returns `Cancelled`. A read timeout counts as idle only when neither
  direction is moving (or writing to a slow peer), so a long one-way
  download doesn't time out. Buffers exist only while data flows, so an
  idle session costs no buffer memory (about 58 KiB per idle TLS session in
  `tls_proxy`, all told). On Linux, between two plain (TCP or Unix) streams,
  it uses `splice`, so the bytes never enter the program's memory.
- **`abort!`** on `Tcp`, `Tls` and `Unix` streams: give up on a connection
  partway through, so the peer sees an error rather than a clean end: a TCP
  reset, with no TLS close_notify (not even when the stream is released).
  Use it instead of `close!` on error paths; `tcp_proxy` does.
- **`Select.on_join(handle, to_out)`**: an arm for a task finishing, for
  acting on whichever of several tasks ends first (such as stopping every
  listener's accept loop when one fails; see `Task.scope!`'s docs).
  `Task.Handle.is_finished!` checks without waiting.
- **Code over any kind of stream**: `Stream`'s docs show the `where` clause
  that annotates a function taking `Tcp`, `Tls` or `Unix` streams, and a tag
  union for keeping listeners of different kinds in one list.
- **Examples**: `tls_proxy` terminates TLS on one listener and serves plain
  TCP on another with the same code, routes by SNI name, and uses
  `copy_both!`.

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
