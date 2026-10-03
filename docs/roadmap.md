# roc-net roadmap: 0.2.0 (concurrency) and beyond

**Status (2026-09-27):** 0.2.0 is implemented (Select, task handles,
cancellation, scopes, `Task.yield!`), except `Time.ticker`, which
`on_timeout` with a remembered deadline covers for now (see
`examples/chat_server`). See CHANGELOG.md.

**Status (2026-09-29):** 0.3.0 (proxy features) is implemented on the
`v0.3-proxy` branch and ready to release: SNI with a certificate per name, ALPN,
`Pipe.copy_both!` (with `splice` on Linux between plain sockets),
`Select.on_join` for acting on whichever task ends first, and the "any
stream" docs and `tls_proxy` example. Crypto + Noise moves to 0.4.

**Status (2026-10-02):** 0.6.0 (sockets, signals, mutual TLS) is
released. The direction changed: protocols are to be built as Roc packages
on the platform, not inside it. See "The platform boundary" and "0.7.0"
below; libp2p moves to later, as a package.

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
- **Host-side bidirectional copy**: `Pipe.copy_both!(a, b)` (or
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

## Next use case: an encrypted chat, as a test, not a target

After the proxy (0.3.x), the next program to build against the platform is
an end-to-end encrypted chat over Noise: 1:1 and peer-to-peer first, a relay
and groups later if at all. It's there to show what's missing and what's
awkward, in the way `tls_proxy` did. It is not a product, and the platform
must not bend towards it. So, for everything this leads to:

1. **The chat lives only in `examples/`.** No platform module gets a
   chat-specific type, name or behaviour.
2. **Every platform addition needs a user other than the chat**, named in
   its plan: libp2p, the proxy, a CLI tool, an existing example. If only the
   chat wants it, it stays in the example.
3. **Specifications decide the shape, not the app.** `Noise` follows the
   Noise spec (rev 34): its names, every handshake pattern, `psk`, checked
   against test vectors and the `snow` crate. What a handshake hands back is
   what the spec defines (the remote static key, the handshake hash), not an
   app notion such as a "fingerprint".
4. **The platform defines no message formats.** The chat's protocol, message
   types, identity file layout, fingerprints, trust-on-first-use list and
   reconnect policy are example code.
5. **The docs test**: every new platform API's doc example is written
   without the chat. If that reads awkwardly, the API is bent towards it.

Where the pieces go:

| Piece | Where | Its users other than the chat |
| --- | --- | --- |
| `Crypto`, the `Noise` handshake and `Noise.Stream` | platform, 0.4 | libp2p (libp2p-noise is XX), any encrypted protocol |
| `File`: read, write, append, create owner-only, rename (atomic replace) | platform, 0.5 | keys, config and state for servers and CLI tools; the proxy's routes |
| stdin as a `Select` arm | platform, 0.5 | any tool reading the terminal and the network at once (an `nc`-style client, a REPL) |
| identity format, fingerprints, `known_peers`, the protocol, reconnecting | `examples/noise_chat` | none: example code |

## 0.4.0: Crypto + Noise (moved from the first draft of this plan)

- Primitives from AWS-LC (already linked): SHA-2, HMAC, HKDF,
  ChaCha20-Poly1305 and AES-GCM, X25519, Ed25519, constant-time compare;
  `Bytes` uvarints.
- **Spike results (2026-09-30, `v0.4-spike`):**
  - *Hosted functions can't be pure.* The compiler rejects a `->` hosted
    function ("Every function the host provides is effectful"), so every
    host primitive is a `!` function, even for pure work such as encrypting.
  - *Roc has a builtin `Crypto`* (nightly-2026-09-24): pure SHA-256 and
    BLAKE3 digests, with incremental hashers, and nothing else ("not ...
    HMAC ... KDF ... or digital signature APIs"). So the platform can't have
    a module called `Crypto` (it shadows the builtin; pick another name), and
    SHA-256, HMAC-SHA-256 and HKDF can be **pure Roc** on the builtin: all of
    Noise's `SymmetricState` hashing and key derivation stays pure. Only
    X25519 and the AEADs (and Ed25519, random keys, the constant-time
    compare) need the host, as `!` functions. Don't write X25519 or
    ChaCha20 in Roc to make them pure: nothing guarantees constant time,
    and it would be slow.
  - *aws-lc-rs as a direct dependency works*: pinned `=1.18.1` with
    `default-features = false, features = ["aws-lc-sys"]`, as rustls takes
    it, so there's one AWS-LC build (`cargo tree -i aws-lc-sys`), for macOS
    and Linux. A spike `sha256!` through it matched the test vectors. It has
    what Noise needs: X25519 from stored key bytes
    (`agreement::PrivateKey::from_private_key`), AEADs with caller-chosen
    nonces (`aead::LessSafeKey`), Ed25519 from a seed, HMAC, and
    `constant_time::verify_slices_are_equal`. The dependency is in
    `Cargo.toml`; the spike code isn't.
  - *Layout (decided)*: one platform module, **`Cryptography`**, with a
    nested type per primitive, as the builtin does `Crypto.SHA256`:
    `Cryptography.X25519`, `.ChaChaPoly`, `.AesGcm`, `.Ed25519`,
    `.HmacSha256`, `.Hkdf`, and `Cryptography.constant_time_eq!`. A spike
    showed nested types work from apps and from other platform modules
    (so `Noise` can use them), `!` functions in them can call the host, and
    imports can be aliased (`import pf.Cryptography as C`). `HmacSha256` and
    `Hkdf` are pure Roc on the builtin SHA-256; the rest are host-backed `!`
    functions. `Noise` stays a module of its own (a protocol, not a
    primitive). Secret keys are opaque types, so `Str.inspect` can't print
    them.
- `Noise` in Roc (rev 34, `25519_ChaChaPoly_SHA256`, patterns as token
  tables: XX, NN, NK, IK, XK, psk), a handshake over any stream, and a
  host-backed `Noise.Stream` (like `src/tls.rs`) so `Framing` works over it.
  After the handshake: the remote static key and the handshake hash (for
  channel binding), as the spec defines them. Transport messages framed with
  the usual 2-byte length prefix (as libp2p-noise does), and longer writes
  split across messages, since Noise caps a message at 65,535 bytes.
- Verify with RFC/NIST vectors, cacophony vectors, and interop against the
  `snow` crate (test-only).
- **Status (2026-10-01):** implemented on `v0.4-noise` and ready to release: `Cryptography`,
  `Noise` (the sans-I/O core, `Noise.Stream`, `handshake!`, `wrap!`), the
  cacophony vectors in `tests/noise`, `Stdin.read_line!` (found by the chat:
  `Stdin.line!` can't tell an empty line from the end of input), and
  `examples/noise_chat`, checked by running two of them against each other.
  Not yet: `Select`, `copy_both!` and `copy_to!` on a `Noise.Stream`; the
  deferred patterns (`NK1` and so on); interop against `snow`.
- Acceptance: `examples/noise_chat`, a minimal 1:1 chat over XX, written
  against the new API (see "Next use case" above for what may and may not
  move into the platform because of it). Its identity key is generated per
  run until 0.5 adds `File`.

## 0.4.1: Small gaps the chat found (released)

From building a relay-based chat against 0.4.0 (2026-10-01); each has users
besides the chat:

- `CipherState.nonce` and `CipherState.with_nonce`: the spec's `SetNonce`
  (§5.1), for transports that can lose or reorder messages (§11.4):
  datagrams, the QUIC/UDP work. Replay windows stay the caller's job.
- `Bytes.to_hex` and `Bytes.from_hex`: printing and parsing keys, hashes and
  binary ids (CLI tools, test vectors, logs).
- `scope.cancel_all!()`: cancel a scope's unfinished tasks without leaving
  it, for "a helper task as long as this block runs" (a proxy's writer, a
  heartbeat). `scope!` still only cancels on its own when the body fails.

## 0.5.0: Files, terminal input, and Select on Noise (released)

Driven by the chat example, justified without it (see the table above):

- `Select` on `Noise.Stream` (and `Pipe.copy_both!` / `copy_to!` over it):
  a non-blocking read in the host that reassembles partial frames. Users:
  libp2p (yamux over Noise), servers that wait on a Noise connection, timers
  and channels at once. Done: the stream keeps ciphertext until it makes a
  whole message, and wakes a `Select` when another reader leaves some.
- Environment variables (`Env.var!`): configuration and secrets for any
  server or CLI tool, beside `File`. Done.
- `File`: read and write whole files, append, create with owner-only
  permissions (for keys), and rename for atomic replacement; errors like
  `IOErr`. Blocking file I/O runs off the task workers, as `Stdin` and DNS
  lookups do (`sched::blocking`), so it can't stall them. Done:
  `write_new!` (create only if absent, with a mode) and `write_atomic!`
  (temporary file, flushed, renamed). Not yet: directories (listing,
  creating), file metadata, and streaming reads of large files.
- stdin in `Select`: an arm for the next line from stdin (or stdin as a
  stream), so a program can wait for the terminal and the network in one
  loop. Done: `on_stdin_line`, with one reader thread and a queue shared by
  every way of reading stdin.
- `examples/noise_chat` grows persistent identities (a key file),
  fingerprints and a `known_peers` file, all in the example. Done, in one
  `Select` loop.

## 0.6.0: Sockets and operations (released)

From reviewing roc-net as a general networking library (2026-10-02); each
is for servers and clients in general, a proxy among them:

- UDP receives say when a datagram was cut short (`truncated`), so a parser
  never takes part of a packet for the whole.
- Socket options: TCP keepalive, buffer sizes, a listener's backlog and
  `SO_REUSEPORT`, a connection's local address or interface, UDP address
  reuse, and Unix peer credentials.
- Signals in `Select` (SIGINT, SIGTERM, SIGHUP, SIGUSR1/2), the piece
  graceful shutdown was missing.
- Examples, not platform code: retries with backoff, a connection pool,
  and draining a server on SIGTERM.
- Found along the way: `Listener.close!`, since draining needs to stop
  taking connections while the listener is still referenced.
- Mutual TLS (client certificates, verifying them, and checking a peer
  certificate's names), moved up from "later".

## The platform boundary (decided 2026-10-02)

The real goal is building general-purpose network protocols, and planning
libp2p showed how one protocol stack can pull its own pieces (peer IDs,
multiaddrs, yamux, protobuf messages) into the platform. Spikes settled
that it doesn't have to: on Roc nightly-2026-09-29, packages can do effects
on roc-net, in three shapes, all verified with an app:

1. **Depending on roc-net**: `package [M] { pf: platform "…/main.roc" }`,
   importing `pf.Tcp`, `pf.Select`, `pf.Task`, ... The `platform` keyword
   is required. This ties the package to an exact roc-net version, so it's
   re-released with each one.
2. **No platform dependency, generic over streams**: effectful functions
   that call `stream.read!` and `stream.write!` through `where` clauses, as
   `Noise.handshake!` does. Works with any version and any stream.
3. **No platform dependency, effects passed in**: the app hands over
   `Task.spawn!` (say) as an argument.

The platform's private `Host` module stays out of reach ("package module is
private"), so packages get the public API and nothing lower. A pure
protobuf wire-format package, also spiked, matched `protoc` byte for byte
in both directions, at about 0.2 µs per small message.

**The rule.** The platform holds only what a package can't:

1. what touches the host: system calls, OS resources, host state (sockets,
   files, signals, the clock, DNS, TLS through rustls);
2. what's wired into the host's machinery: scheduler waits, `Select` wait
   sources, host-side copies (`Pipe`), stream kinds the scheduler knows;
3. hot paths that want native code (bulk crypto, copying).

Everything else, protocol logic and encodings above all, is a package:
platform-free (shapes 2 and 3) wherever it can be, since those aren't tied
to a roc-net version.

**What's in the platform now, by that rule**:

| Module | Why it's in the platform |
| --- | --- |
| `Tcp`, `Udp`, `Unix`, `Tls`, `Dns`, `File`, `Env`, `Stdin`/`Stdout`/`Stderr`, `Signal`, `Time`, `Random`, `Log` | the host |
| `Task`, `Channel`, `Select` | the scheduler |
| `Pipe`, `Framing` | host-side copies (`Framing.Reader.copy_to!`), and the stream methods every protocol reads with |
| `Cryptography` (X25519, AEADs, Ed25519) | AWS-LC, native |
| `Noise` | `Noise.Stream` is a stream kind the host knows (partial messages for `Select`, `Pipe`); the handshake is pure, but produces that stream |
| `Bytes`; `Cryptography.HmacSha256` and `HkdfSha256` | pure, and would be packages if written today; kept, as moving them would break every user for little gain |
| `IOErr`, `Host` | the platform's own types |

So: no new pure protocol logic goes into the platform. Moving released
modules out is not worth the churn on its own; a later breaking release can
reconsider `Bytes` if a pure "basics" package appears.

## 0.7.0: Protocol packages (ready to release)

**Decided (2026-10-02):** packages live in this repo, under `packages/`,
each versioned and released on its own.

How Roc brings them in (nightly-2026-09-29): there's no registry. A
dependency is a relative path (for development) or an https URL to a
`roc bundle` archive, named by its hash and checked against it. A bundle
has one root `main.roc`, so the platform and every package are separate
bundles, each at its own URL; one package can hold many modules. A version
in the URL path (`…/protobuf/0.1.0/<hash>.tar.zst`) takes part in
resolution: 0.x versions group by minor (1.x and up by major), the build
uses the highest version mentioned in a group, and apps pin exactly (a
dependency needing a newer version than the app names is an error, not an
upgrade). So a package built on roc-net 0.6.0 works with any 0.6.x, and
only a roc-net minor release (a breaking one) means re-releasing it.

**The platform side** is small, and only what packages can't do:

- **A parse hook (done)**: `reader.read_parsed!(parse)` and
  `Select.on_parsed(reader, parse, to_out)`, where `parse` is a pure
  function of the reader's buffered bytes, answering "a value, using n
  bytes" or "need more". Then any framing (varint lengths, MQTT, RESP, HTTP
  headers) lives in a package and still works in `Select`; `on_line` and
  `on_frame` become two built-in parsers. Varint framing itself would then
  be package code, not platform code.

**Layout and releasing:**

- `packages/NAME/` holds `main.roc` (`package [Modules] { deps }`), its
  modules, a `CHANGELOG.md`, and tests that `just test` and CI run.
- During development, dependencies are relative paths: another package
  (`"../protobuf/main.roc"`) or the platform
  (`platform "../../platform/main.roc"`).
- `just release-package NAME VERSION` bundles one package and uploads it to
  the project's generic package registry as
  `…/packages/generic/NAME/VERSION/<hash>.tar.zst`, tagged `NAME-vVERSION`.
  A published bundle can't use relative paths that point outside it, so the
  release rewrites each one to a released URL, the platform's and other
  packages', and refuses if one of them isn't released yet (release order:
  dependencies first).
- Pure packages with no dependencies (`protobuf`) need no rewriting.

**First packages:**

- **`protobuf`** (done, 0.1.0 ready to release; pure): the wire format (varints, zigzag, fixed32/64,
  length-delimited fields, walking a message's fields, packed repeated
  fields), tested against `protoc` in both directions. Schemas are code on
  top of it: written by hand, or later generated from `.proto` files.
- **`resp`** (done, 0.1.0 ready to release; generic over streams, checked
  against Valkey 8 with `just interop-valkey`): the Redis serialization protocol, a
  client for the common commands, and an example using it.
- Then, as they're wanted: base58 and base64 (pure), MQTT, WebSocket and
  HTTP/1.1, each stressing the platform differently (binary framing,
  long-lived pub/sub, upgrading a connection, pipelining). What they find
  missing goes into the platform under the rule above.

## Later

- libp2p over TCP, as a package on roc-net and `protobuf`: peer IDs,
  libp2p-noise (Noise XX with a signed payload), multistream-select, yamux
  (Select and scopes), identify, ping; interop with rust-libp2p. The big
  proof that a full protocol stack can live downstream.
- A sans-I/O UDP foundation with QUIC (quinn-proto) in the platform (it's
  host-level: native crypto, timers, packets); libp2p over QUIC.
- Then DTLS (rtc-dtls with aws-lc vs dimpl), mDNS/STUN/NAT traversal (and
  UDP multicast interface, hop limit and packet info for them), WebSocket,
  libp2p's TLS (self-signed certificates, checked its own way), TLS
  listener options (backlog, port reuse), a deterministic network
  simulator.
