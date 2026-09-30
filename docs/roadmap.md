# roc-net roadmap: 0.2.0 (concurrency) and beyond

**Status (2026-09-27):** 0.2.0 is implemented (Select, task handles,
cancellation, scopes, `Task.yield!`), except `Time.ticker`, which
`on_timeout` with a remembered deadline covers for now (see
`examples/chat_server`). See CHANGELOG.md.

**Status (2026-09-29):** 0.3.0 (proxy features) is implemented on the
`v0.3-proxy` branch and ready to release: SNI with a certificate per name, ALPN,
`Stream.copy_both!` (with `splice` on Linux between plain sockets),
`Select.on_join` for acting on whichever task ends first, and the "any
stream" docs and `tls_proxy` example. Crypto + Noise moves to 0.4.

## Context

Every later goal (yamux and libp2p, gossip, ICE, a chat server with
heartbeats) needs two things tasks can't do today:

- **Wait for whichever happens first.** A task waits on exactly one thing
  (a socket read, a channel receive, a sleep). "A message from the peer, a
  message to send, or 30 s of silence" means a task per source feeding a
  channel.
- **Manage task lifetimes.** `Task.spawn!` is fire-and-forget: no result,
  no waiting for it, no stopping it, nothing tying a connection's helper
  tasks to the connection.

Decided with the user: `Select` as a builder with a callback per arm
(type-safe across arms of different types), and task handles with `join!`,
cooperative `cancel!` and `Task.scope!`. Crypto + Noise moves to 0.3 (plan
below, unchanged).

## Target API

```roc
next = Select.new()
    .on_read(stream, 4096, |result| FromPeer(result))   # Try(List(U8), err)
    .on_receive(outbox, |result| ToSend(result))       # Try(a, [Closed])
    .on_timeout(Time.seconds(30), || Idle)
    .wait!()?                                           # Err only if cancelled

handle = Task.spawn!(|| fetch!(url))?     # Handle(ok, err)
result = handle.join!()                   # the task's own Try(ok, err)
handle.cancel!()

Task.scope!(|scope| {
    a = scope.spawn!(|| fetch!("a"))?
    b = scope.spawn!(|| fetch!("b"))?
    Ok((a.join!()?, b.join!()?))
})  # when the body returns, unfinished children are cancelled and awaited
```

## Step 0: Roc spikes (they decide the shapes below)

- An opaque `Select(out)` holding a list of arms whose records contain
  effectful closures (`poll! : {} => ...`) built from generic, differently
  typed sources, with static-dispatch methods (`.on_read`) that are generic
  over the stream type.
- A hosted function taking `List` of a tag union of handles
  (`[Readable(Socket), Receivable(ChannelEnd), ...]`); check the glue.
- `Handle(ok, err)` carrying a channel receiver plus a task handle.
Fallbacks if something doesn't typecheck: arms as a list of closures only
(no records), or `on_*` as free functions.

## 1. Host: wait on several sources at once (`src/sched.rs`)

The pieces already exist: a wait has one id, and `wake(task, wait, ..)`
claims it by compare-and-swap, so the first of several sources to fire wins
and the rest are ignored.
- `TaskWaker: Clone`; `Waiters::add_waker(waker)` so one wait id can sit in
  several lists (today `add()` starts a new wait per call).
- `wait_any(sources, deadline)`: begin one wait; register it on each
  source: a socket's `IoState` waiters (readable/writable, same code as
  `wait_io`, including moving the socket's registration), a channel's
  `receivers`/`senders` `Waiters` (`src/channels.rs`), and the timer;
  suspend; on resume remove it from every source it was registered on
  (remove-by-wait-id). Returns Ready / TimedOut / Cancelled; spurious
  wake-ups are fine (the caller polls again).
- Hosted `select_wait! : List(WaitSource), U64 => [Ready, TimedOut,
  Cancelled]`.

## 2. Non-blocking operations for arms to poll

- `socket_try_read!` (TCP, Unix, UDP connected, TLS): like `read_stream`
  in `src/net.rs` but returns `WouldBlock` instead of waiting. For TLS:
  `TlsStream::try_read` already never waits; add a non-blocking `fill`
  (read what the socket has, send pending records without waiting).
- Channels already have `try_receive!` / `try_send!`.
- `Framing.Reader` arms (`on_line`, `on_frame`): poll the reader's buffer
  first, then its stream; readiness is the underlying stream's.

## 3. `Select` module (`platform/Select.roc`, Roc)

- Arms: `on_read`, `on_receive`, `on_send` (value waiting for room),
  `on_timeout`, `on_line`/`on_frame` (Framing readers), `on_ready` (another
  Select's source list, for composition later if cheap).
- `wait!`: poll every arm without blocking, starting at a rotating index
  (fairness: a busy arm can't starve the others); the first that produces a
  value wins. Otherwise `select_wait!` on all arms' sources with the
  earliest timeout as deadline, then poll again. An arm's result includes
  its errors (`Try`), so a closed socket is a value, not an exit.
- Docs: which arm wins when several are ready (rotation), and that nothing
  is consumed from arms that didn't win.

## 4. Task handles, cancellation, scopes

Host (`src/tasks.rs`, `src/sched.rs`):
- `Task` gets `cancelled: AtomicBool` and a finished flag plus `Waiters`
  for joiners. `cancel` sets the flag and wakes the task's current wait
  with `Woke::Cancelled` (a third wake reason). Every wait checks the flag
  when it starts and ends.
- Cancelled waits surface as errors: `IOErr` gains `Cancelled`
  (`platform/IOErr.roc`, `io_err!` in `src/net.rs`), channel operations gain
  `Cancelled`, `Select.wait!` returns `Err(Cancelled)`, `Time.sleep!`
  returns early (and `Task.is_cancelled!` lets a compute loop check).
- A task handle is a host resource (a `ResourceHeap` like channels,
  `src/resource.rs`) pointing at the `Arc<Task>`; `task_cancel!`,
  `task_wait_done!`. Scopes: a host group of child tasks; `scope_close!`
  cancels unfinished children and waits for them.
- Cooperative by design: a task that ignores `Cancelled` keeps running.
  Document it; `?`-style code unwinds, and sockets close as values drop.

Roc (`platform/Task.roc`):
- `spawn!` returns `Try(Handle(ok, err), [TaskLimitReached])`; the result
  travels back through a capacity-1 channel (`platform/Channel.roc`), so
  `join!` is a receive. Unjoined handles are fine (the task is detached,
  as today; the stderr log of a failed task stays for detached ones only).
- `Task.scope!(body)`, `scope.spawn!`.
- Update `examples/` and docs for the new `spawn!` result (servers use
  `_ = Task.spawn!(...)` today, which still works).

## 5. Small additions

- `Task.yield!` (hosted, `Suspend::Yield` in `src/sched.rs`): lets a long
  computation give other tasks a turn.
- `Time.ticker(period)` for Select: an arm that fires every period without
  drift.

## 6. Prove it on examples

- Rewrite `examples/chat_server` with one task per client using `Select`
  (peer input, broadcast channel, idle timeout, heartbeat) instead of
  helper tasks.
- `examples/tcp_proxy` with `Task.scope!`: both directions in a scope, so
  either side closing tears the pair down.
- A fan-out example: fetch N addresses concurrently, first success wins,
  the rest are cancelled.

## Verification

- `examples/net_tests` additions:
  - Select: each arm kind wins; several ready at once rotate fairly;
    timeout; a socket closing mid-wait; a TLS stream with buffered
    plaintext (ready without the socket being readable); nothing consumed
    from losing arms (a channel value stays for the next receive); a stale
    wake after a timeout is ignored.
  - Handles: join returns the task's result; join after it finished;
    cancel wakes a task blocked in read, receive, sleep and Select, and its
    socket closes; cancel twice; cancelling a finished task.
  - Scopes: early return cancels siblings; a child failing; nested scopes;
    joining from outside; the task limit inside a scope.
- Every test also runs in the stealing pass (`scripts/run_net_tests.sh`,
  `ROC_NET_SHARE_AFTER_US=0`), since multi-source waits and cancellation
  race with task migration.
- `just test`, `just linux-test`, `just test-bundle`; `just bench` to check
  plain request-response didn't slow down (single-source waits must keep
  their current path).

## 0.3.0: Proxy features

From building a TLS-terminating reverse proxy on 0.2:

- **SNI**: after the handshake, `stream.server_name!()` returns the name the
  client asked for (rustls `ServerConnection::server_name()`). Several
  certificates chosen by name, such as `Tls.server_config_multi([{ name,
  cert_file, key_file }, ...])` (rustls `ResolvesServerCertUsingSni`), with a
  default for clients that send no name. ALPN fits here too
  (`with_alpn([...])`, `stream.alpn_protocol!()`).
- **Host-side bidirectional copy**: `Stream.copy_both!(a, b)` (or
  `copy_to!`) doing the proxy loop in Rust: half-close passed through,
  errors and cancellation handled in one place, no Roc list per chunk
  (TLS through `fill`/`try_read`), and room for `splice` on Linux later.
  `examples/tcp_proxy` becomes its test.
- **Code over "any stream"**: a documented way to annotate functions that
  take either `Tcp` or `Tls` streams (a `where` clause over the methods, if
  the compiler allows it), and an example keeping mixed listeners in one
  list (or a tag union with a small dispatcher).
- A `Select` arm for a task finishing (`on_join`), which covers stopping
  every task when the first one ends (see `Task.scope!`'s docs).

## 0.3.2: Structured logging with a non-blocking sink

**Status (2026-09-30):** implemented on the `v0.3.2-log` branch and ready to release: `Log`
(`platform/Log.roc`, `src/log.rs`), `Time.utc_now!` and `Time.Utc`, task ids,
and the platform's own messages routed through it. See `Log`'s docs for the
behaviour and the CHANGELOG for the summary. As built:

- One writer thread, not a task worker, drains a queue of whole, formatted
  lines to stderr, a batch at a time, pausing a millisecond between batches
  so a busy server doesn't wake it for every line (that cut the cost of a
  line from about 5 to 1-2 µs). It blocks SIGPIPE for itself. It writes under
  Rust's stderr lock, which `Stderr.line!` also holds while writing a line,
  so the two never tear each other's lines (writing to the file descriptor
  directly let a batch land inside one); `tests/log`'s `mixed` mode checks
  it.
- Memory: lines queued plus the batch being written stay within
  `ROC_NET_LOG_BUFFER_KIB` (1 MiB by default), give or take a line; batches
  are at most a sixteenth of it. When full, the **oldest** queued lines are
  dropped and counted in a `log lines dropped` warning. Strings past 16 KiB
  and lines past 64 KiB are cut short and marked.
- Text (the default) or JSON (`ROC_NET_LOG_FORMAT`); a text message
  containing `=` or `"` is quoted, so interpolated data can't pass for
  fields. Floats are written in their shortest form.
- `task`: 1 for `main!`, counting up; no field outside a task.
- `Stderr.line!` is unchanged (synchronous, lossless); its docs point
  servers at `Log`. `main!` failing and detached tasks failing are logged at
  error level; `ROC_NET_LOG=off` silences them too (the exit code still
  reports `main!` failing). When `main!` returns, the queue gets up to a
  second.
- Tests: `tests/log` and `scripts/run_log_tests.sh` check the exact lines in
  both formats, levels and settings, truncation, `main!` failing (including
  with stderr stalled, where it must still exit), and a stalled stderr
  (20,000 lines logged in about 10 ms, the oldest dropped, every line
  written or counted). `scripts/run_net_tests.sh` runs them when the program
  is built alongside `net_tests`, and says SKIPPED when it isn't. There are
  no Rust unit tests: the host library doesn't link without Roc's symbols.
- Measured (macOS, 64 connections, one line per request): about 1-2 µs of
  server CPU per line to `/dev/null`, against about 8 µs for
  `Stderr.line!`; with a stalled stderr, `Log` carries on at full speed and
  `Stderr.line!` stops the server.

## 0.4.0: Crypto + Noise (moved from the first draft of this plan)

- `Crypto` from AWS-LC (already linked): SHA-2, HMAC, HKDF, ChaCha20-Poly1305
  and AES-GCM, X25519, Ed25519, constant-time compare; `Bytes` uvarints.
  Spike first: whether hosted functions may be pure (`->`), and aws-lc-rs as
  a direct dependency at rustls's version.
- `Noise` in Roc (rev 34, `25519_ChaChaPoly_SHA256`, patterns as token
  tables: XX, NN, NK, IK, XK, psk), a handshake over any stream, and a
  host-backed `Noise.Stream` (like `src/tls.rs`) so `Framing` works over it.
- Verify with RFC/NIST vectors, cacophony vectors, and interop against the
  `snow` crate (test-only).

## Later

- 0.5: libp2p over TCP (peer IDs, libp2p-noise, multistream-select, yamux on
  Select + scopes, identify, ping), interop with rust-libp2p.
- 0.6: sans-I/O UDP foundation with QUIC (quinn-proto); libp2p over QUIC.
- Then DTLS (rtc-dtls with aws-lc vs dimpl), mDNS/STUN/NAT traversal,
  WebSocket, mTLS/ALPN, graceful shutdown, a deterministic network simulator.
