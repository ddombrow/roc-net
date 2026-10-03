# Changelog

Releases are published on
[GitLab](https://gitlab.com/ddombrow/roc-net/-/releases). Each one names the
Roc nightly it's built for; apps must use that nightly.

## 0.7.0 (unreleased)

Added:

- **`Framing.Reader.read_parsed!(parse)`** and **`Select.on_parsed`**: read
  messages of any framing with a pure function of the buffered bytes
  (`Parsed(value, used)`, `NeedMore` or `Malformed(err)`), with the same
  limits, timeouts and `Idle` as lines and frames. Protocol packages can now
  read their messages, and wait for them in a `Select`, without the
  platform knowing their format.
- **Packages** in `packages/`, each versioned and released on its own
  (`just release-package NAME VERSION`): `protobuf` 0.1.0 and `resp` 0.1.0
  (see their own CHANGELOGs).

## 0.6.0

Built for Roc `nightly-2026-09-29-7f11a82`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Breaking:

- **UDP receives say when a datagram was cut short.** `recv_from!` returns
  `{ bytes, from, truncated }`, and `recv!` returns `{ bytes, truncated }`
  instead of the bytes alone. Before, a datagram longer than `max` was cut
  with nothing to say so.

Added:

- **`Signal`**: catch SIGINT, SIGTERM, SIGHUP, SIGUSR1 and SIGUSR2
  (`Signal.catch!`), then wait for them with `Signal.next!` or a `Select`'s
  `on_signal` arm, alongside connections and timers.
- **`Listener.close!`** (`Tcp`, `Unix`, `Tls`): stop taking connections now;
  `accept!`, even one already waiting or just starting to, fails with
  `NotConnected`.
- **Mutual TLS.** Servers: `Tls.server_config(...).with_client_auth(ca_file,
  Required)` (or `Optional`) verifies client certificates against that CA.
  Clients: `Tls.client_config.with_client_cert({ cert_file, key_file })`.
  Either side: `stream.peer_certificates!()` (the other side's chain, DER)
  and `stream.peer_certificate_valid_for!(name)`, for deciding what a
  verified client may do.
- **Socket options**: `set_keepalive!` on TCP and TLS streams; receive and
  send buffer sizes on TCP, TLS, Unix and UDP sockets; a listener's backlog
  (now 1024 by default) and `SO_REUSEPORT` (`Tcp.listen_config`); a
  connection's local address or interface (`Tcp.connect_with!`); UDP address
  reuse (`Udp.bind_with!`); `Unix.Stream.peer_credentials!`.
- **Examples**: `retry_backoff` (exponential backoff with jitter),
  `connection_pool` (a bounded, lazily filled pool that replaces broken
  connections) and `graceful_server` (draining on SIGTERM: in-flight requests
  finish, idle connections close, the rest are cancelled after a grace
  period).

Fixed:

- **`Random.bytes!` reports running out of memory in every case.** It
  allocated twice, and the second allocation, the Roc list itself, still
  ended the program on failure. It now allocates the list once, in a way
  that can fail, and fills it in place. (The host now has its own
  allocator, laid out as the glue's was, so the two can't drift apart.)
- **A line of exactly 1 MiB ending in `\r\n` was refused** as too long by
  `Stdin.read_line!` and `Select.on_stdin_line`: the `\r` was counted
  towards the limit, which is meant to exclude the line ending.

## 0.5.1

Built for Roc `nightly-2026-09-29-7f11a82`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Fixed:

- **A socket could stop getting wake-ups**, so a task waiting on it sat
  until its timeout with data waiting (or for ever, without one). Closing a
  socket closed its descriptor and only then removed its event-queue
  registration, by descriptor number. In between, another thread could open
  a socket and get the same number, and its registration was the one
  removed. It needed sockets opening and closing at once on different
  threads, so it was rare, and more likely the busier a server got; it has
  been there since the scheduler arrived. A new stress check
  (`tests/fd_reuse`), which lost 7 to 24 wake-ups in 10 seconds before the
  fix, loses none after it.

## 0.5.0

Built for Roc `nightly-2026-09-29-7f11a82`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Breaking:

- **`Random.bytes!` returns a `Try`**, failing with `TooManyBytes` past
  16 MiB (before allocating anything) and with `OutOfMemory`, instead of
  stopping the program when a huge count (from untrusted input, say) can't
  be allocated: `key = Random.bytes!(32)?`. The fixed-size functions
  (`u64!`, `between!`, ...) are unchanged.

Added:

- **`File`**: read, write, append, rename and delete whole files, and check
  whether one exists. `write_new!` creates a file only if it doesn't exist,
  with the permissions given (`0o600` for a secret key); `write_atomic!`
  replaces one. Both write a temporary file and flush it to disk first
  (`write_new!` then hard-links it into place, `write_atomic!` renames it),
  so the file only ever appears complete, even after a crash. On file
  systems without hard links (FAT, exFAT), `write_new!` creates the file
  directly instead. Calls run on helper threads, like DNS lookups,
  so they never stall other tasks. Errors are `FileErr(IOErr)`.
- **`Env.var!`**: read an environment variable.
- **`IOErr.AlreadyExists`**, from `File.write_new!`. Code that matches every
  `IOErr` tag without a `_` case needs the new one.
- **A 1 MiB limit on stdin lines.** `Stdin.read_line!` and
  `Select.on_stdin_line` fail with a new `LineTooLong` error for a longer
  line, and skip the rest of it, so untrusted input can't use up memory
  (`Stdin.line!` fails with `StdinErr`). Code that matches every error of
  `read_line!` needs the new tag.
- **`Select` on `Noise.Stream`**, and `Pipe.copy_both!` / `copy_to!` with
  it: a Noise connection can share one loop with channels, timers and other
  streams, instead of needing a task per direction.
- **`Select`'s `on_stdin_line`**: wait for a line typed, alongside the
  network, in one loop.
- **`examples/noise_chat`** keeps its identity key in a file (owner-only),
  remembers each peer's key, and warns if a name comes back with a different
  one. It now runs in one `Select` loop, and its fingerprints are 128 bits
  (they were 64).

Fixed:

- Two `Select`s waiting on one idle TLS stream woke each other in a loop,
  using most of a CPU core between them (since `Select` arrived). A lock
  release that only found the socket empty now wakes just the waiters that
  arrived while the lock was held (they never got to look at the socket),
  and a waiter that finds the lock free checks the socket itself before
  sleeping. The same applies to `Noise.Stream`. A new check
  (`tests/select_idle`) times it, and two new tests share a stream between
  two Select readers.
- After a message failed to authenticate, a `Noise.Stream` carried on: the
  next message decrypted, and the bad one went missing unnoticed. Every read
  after a bad message now fails.
- A `Noise.Stream` read that timed out partway through a message lost the
  part it had read, so the next read misread the stream. Partial messages
  are now kept.
- A line typed while the task reading stdin was cancelled was lost. All
  stdin reads (`Stdin.line!`, `read_line!`, the `Select` arm) now take lines
  from one queue, in order.

## 0.4.1

Built for Roc `nightly-2026-09-29-7f11a82`, with hosts for macOS (arm64,
x86-64) and static Linux (musl: arm64, x86-64).

Added (from building a relay-based chat on 0.4.0):

- **`CipherState.nonce` and `CipherState.with_nonce`**: the Noise spec's
  `SetNonce`, for transports that can lose or reorder messages (datagrams):
  send each message's nonce with it, and set it before decrypting. Keeping a
  replay window is up to the caller.
- **`Bytes.to_hex` and `Bytes.from_hex`**: lowercase hex out; upper- or
  lowercase in, with `InvalidHex({ index })` for the first bad character.
- **`scope.cancel_all!()`**: cancel a `Task.scope!`'s unfinished tasks from
  inside its body, without leaving it, for helper tasks that should last
  only as long as the body (a connection's writer while the body reads).
  `scope!` still waits for them, and still cancels on its own only when the
  body fails.

## 0.4.0

Built for Roc `nightly-2026-09-29-7f11a82` (0.3.2 was built for
`nightly-2026-09-24-f45bfbe`), with hosts for macOS (arm64, x86-64) and
static Linux (musl: arm64, x86-64). Apps must move to the new nightly.

Breaking:

- **The `Stream` module is now `Pipe`**: `Pipe.copy_both!` and
  `Pipe.copy_to!` (and `import pf.Pipe`). Roc's builtins have a `Stream`
  type (an effectful iterator), which the platform's own modules saw in
  place of ours, so they couldn't use it. The stream types (`Tcp.Stream`
  and so on) keep their names.

Added:

- **`Cryptography`**: `X25519` (RFC 7748, rejecting low-order points),
  `ChaChaPoly` (RFC 8439) and `AesGcm` (AES-256-GCM), `Ed25519` (RFC
  8032), `HmacSha256` (RFC 2104) and `HkdfSha256` (RFC 5869), and
  `constant_time_eq!`. Host-backed by AWS-LC (the same build rustls uses),
  so most are `!` functions; HMAC and HKDF are pure Roc on the builtin
  `Crypto.SHA256`. Keys and nonces are types whose lengths are checked when
  they're made; secret keys are opaque and have no `==`. Checked against
  each RFC's test vectors.
- **`Noise`**: the Noise Protocol Framework, revision 34, with the one-way
  (`N`, `K`, `X`) and interactive (`NN` ... `IX`) patterns, pre-shared keys
  (`XXpsk3` and so on), 25519, ChaChaPoly or AESGCM, and SHA256.
  - `Noise.handshake!(stream, config, payloads)` runs a handshake over a
    TCP or Unix stream (each message with a 2-byte length, as libp2p-noise
    frames them) and returns a `Noise.Stream`, the handshake hash, the other
    side's static key, and its handshake payloads.
  - `Noise.Stream` has the same methods as `Tcp.Stream`, so `Framing` works
    over it; it's full-duplex, and splits writes past a Noise message's
    65,519 bytes. Not yet supported on it: `Select`, `copy_both!`,
    `copy_to!`.
  - Underneath, the specification's sans-I/O interface: `Noise.start!`,
    `Handshake.write_message!` / `read_message!` / `finish`, `CipherState`,
    and `Noise.wrap!` to turn a finished handshake into a stream.
  - Checked against the 72 cacophony test vectors for these patterns and
    ciphers (every message, the handshake hash, and transport messages), in
    `tests/noise`, generated by `scripts/gen_noise_vectors.py`.
- **`Stdin.read_line!`**: `Line(text)` or `End`, since `Stdin.line!`
  returns `""` both for an empty line and at the end of input.
- **Examples**: `noise_chat`, an end-to-end encrypted 1:1 chat over Noise
  `XX`, with fingerprints to compare and names sent in the handshake
  payloads.

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
