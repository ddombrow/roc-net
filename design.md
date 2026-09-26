# roc-net design

## Purpose

roc-net is a Roc platform for writing network programs: custom protocols,
servers, clients, proxies, and tools, over TCP, UDP, and Unix domain sockets.
It is a toolkit, not a framework. It provides sockets, concurrency, timeouts,
and name resolution, then gets out of the way.

Compare [basic-webserver](https://github.com/roc-lang/basic-webserver): it
owns the HTTP server and calls Roc once per request, and it excludes raw byte
streams, long-lived bidirectional protocols, and arbitrary background work.
Those are roc-net's core use cases. For a conventional HTTP service,
basic-webserver remains the better choice.

## Principles

1. **Primitives, not policy.** Expose sockets close to their OS semantics,
   with typed errors. Protocol logic (framing, parsing, state machines,
   retries) lives in Roc, where it is testable as pure code.
2. **Sequential code, host concurrency.** Applications write blocking,
   top-to-bottom code: `read!`, then parse, then `write!`. Concurrency comes
   from spawning tasks, not from callbacks. The scheduler is a host
   implementation detail that can change without changing the Roc API.
3. **The host owns OS resources; Roc owns values.** Sockets live in host
   tables. Roc holds opaque handles and never sees file descriptors or native
   pointers.
4. **Everything is bounded.** Reads, task counts, handle tables, and queues
   have finite limits and a typed error at saturation. No operation waits
   forever unless the application asks it to.
5. **One stream vocabulary.** TCP streams, Unix streams, and (later) TLS
   streams share the same method names and shapes, so framing code written
   once works over all of them via static dispatch.

## Application contract

```roc
main! : List(Str) => Try({}, [Exit(I32), ..])
```

A single `main!` suits both one-shot clients and long-running servers. A
server is `main!` looping on `accept!` and spawning a task per connection.
There is no separate init/respond/shutdown contract.

## Concurrency model

```roc
Task.spawn! : (() => {}) => Try({}, [TaskLimitReached])
```

- A task runs a Roc closure to completion. Tasks may run **in parallel**, so
  applications must not assume two tasks never overlap. (Roc values are
  immutable and refcounts are atomic, so this is a constraint on host
  resources, not on Roc values.)
- Blocking effects block only the calling task.
- Live tasks are bounded. Spawning past the limit (or when the OS refuses a
  thread) fails with `TaskLimitReached` and releases the closure, so anything
  it captured, such as a connection, is closed. Spawning never waits or
  queues: with a thread per task, that deadlocks tasks that depend on each
  other. A proxy's connection task spawns the task for the other direction;
  if every slot is held by a task waiting to spawn, none ever finishes.
  Servers shed load by ignoring the error in their accept loop
  (`_ = Task.spawn!(...)`), and must not end `main!` on it.
- An uncaught task error is logged to stderr and ends only that task.

**Implementation, phase 1: OS threads.** Each task runs on its own thread from
a bounded pool, and effects use blocking `std` sockets. basic-webserver already
runs Roc concurrently on several threads, and Roc's builtins use atomic
refcounts by default (`RC_TYPE = .atomic` in `src/builtins/utils.zig`). This is
the smallest correct implementation, and it scales to low thousands of
connections.

**Possible phase 2: stackful coroutines.** Tasks become coroutines on a small
number of Roc threads (a `corosensei` stack per task over a `mio` event loop),
as roc-ray does with `zio`. This allows many more connections per process. It
changes no Roc API, which is why the API promises only "may run in parallel",
a property that both implementations satisfy.

**Communication between tasks** goes through `Channel`: bounded,
multi-producer, multi-consumer queues. `send!` waits while full and
`receive!` while empty; `try_send!`, `try_receive!`, and `receive_timeout!`
don't wait (or wait a bounded time). Values cross the host as thunks,
`Box(() -> a)`: a boxed closure has a fixed shape whatever `a` is, and carries
its own drop callback, so the host can queue values of any type and free the
ones never received. Each channel has one sender end and one receiver end,
Roc-owned handles in their own resource heap (`ROC_NET_MAX_CHANNELS`, default
8,192). Releasing the sender (or `close!`) lets receivers drain the queue and
then get `ChannelClosed`; releasing the receiver makes sends fail instead of
waiting forever. The host never frees a queued value while holding a
channel's lock, since freeing can run Roc drop code that releases other
handles, including that channel's.

A value is released after its last use, but the exact moment within a
function isn't guaranteed (a value discarded with `_` may live until the
function returns); returning from the function or task that holds it is the
reliable point, and `close!` closes at a specific one.

## Resources and lifetime

Sockets are ARC-owned handles, as in basic-webserver's `host_resource.rs`
(`src/resource.rs`). A handle is a Roc `Box(U64)` whose allocation is a slot in
a fixed host heap: an atomic refcount followed by a (generation, index) token.
When Roc releases the last reference it deallocates the slot's address, and
`roc_dealloc` (and the `RocHost` dealloc the glue helpers use) routes that
address to the heap, which drops the socket and frees the slot. Every lookup
checks the token, so a handle whose slot was reused is rejected.

`Stream.close!` shuts a stream down early (for example, so a task blocked
reading it wakes up); the socket itself is freed when its last reference goes.
Listeners have no `close!`. When the socket heap is full, `listen!` and
`connect!` fail with `TooManySockets`, while `accept!` waits for a slot, so
new clients wait in the kernel's accept queue (backpressure) rather than
being accepted and dropped. `accept!` also retries errors that only mean "try
again" (an aborted connection, or being out of file descriptors).

Invariant: platform Roc code never `Box.unbox`es or re-boxes a handle. The
compiler's box-reuse rewrite (`lir/box_reuse.zig`) only fires on
`box_box(f(box_unbox(b)))`, and that would recycle a handle's memory without
calling `roc_dealloc`.

Concurrent use of one resource from two tasks is memory-safe. Each resource
has its own lock, and a conflicting operation either waits or returns `Busy`,
chosen per operation and documented.

## Modules

| Module | Contents |
| --- | --- |
| `Tcp` | `listen!`, `connect!`; `Listener.accept!`; `Stream` read/write methods, `shutdown!` (half-close), `set_nodelay!`, addresses |
| `Udp` | `bind!`; `Socket.send_to!`, `recv_from!`; `connect!` then `send!`/`recv!`; broadcast, multicast join/leave |
| `Unix` | stream `listen!`/`connect!` (same `Stream` methods as `Tcp`) on filesystem paths; datagram sockets and Linux abstract names later |
| `Dns` | `resolve!` a host name to a list of addresses, via the OS resolver |
| `Task` | `spawn!`, and later `Channel` |
| `Time` | monotonic `now!` / `Instant`, `Duration`, `sleep!` (deadlines later) |
| `Random` | secure random numbers from the TLS crypto provider's CSPRNG (AWS-LC, seeded by the OS) |
| `Bytes` (pure) | big/little-endian `U16`/`U32`/`U64` encoding and decoding, `take`, `take_u8` |
| `Framing` (Roc) | a buffered reader over any stream: `read_line!`, `read_until!`, `read_exactly!`, length-prefixed frames; `each_`/`fold_` loops |
| `Tls` (later) | rustls client and server, producing a stream with the shared methods |
| `Stdout`, `Stderr`, `Stdin` | existing |

### Shared stream methods

Every stream type (`Tcp.Stream`, `Unix.Stream`) provides these, with its
module's error tag (`TcpErr(IOErr)`, `UnixErr(IOErr)`):

```roc
read! : s, U64 => Try(List(U8), _)         # up to n bytes; [] means EOF
write! : s, List(U8) => Try({}, _)         # all bytes
write_str! : s, Str => Try({}, _)
shutdown! : s, [Read, Write, Both] => Try({}, _)
set_read_timeout! : s, [NoTimeout, Millis(U64)] => Try({}, _)
set_write_timeout! : s, [NoTimeout, Millis(U64)] => Try({}, _)
local_addr! : s => Try(Str, _)
peer_addr! : s => Try(Str, _)
close! : s => {}
```

A function that only calls these methods needs no annotation: Roc infers it
as generic over any type that has them. `examples/net_tests` uses the same
unannotated `read_to_end!` and `exchange!` helpers with TCP and Unix streams.
`Framing` works the same way, so it covers every current and future stream
type.

On the host side, every kind of socket is one `Host.Socket` handle, and one
set of hosted functions (`socket_read!`, `socket_write!`, ...) serves all of
them, checking the socket's kind at runtime. The public modules wrap that
handle in distinct opaque types, so apps can't mix the kinds up.

### Errors

A shared `IOErr` tag union mapped from `std::io::ErrorKind`:
`ConnectionRefused`, `ConnectionReset`, `ConnectionAborted`, `BrokenPipe`,
`TimedOut`, `AddrInUse`, `AddrNotAvailable`, `NotFound`, `PermissionDenied`,
`WouldBlock`, `Interrupted`, `InvalidInput`, `UnexpectedEof`, `Closed`,
`Busy`, `CapacityExhausted`, `Other(Str)`.

Structured tags also avoid a current compiler hazard: `?` miscompiles on
single-variant error unions (roc#9826, noted in basic-webserver's `Tcp.roc`),
and today's `[TcpErr(Str)]` is exactly that shape.

### Addresses

Addresses are strings at the API edge (`"127.0.0.1:8080"`, `"[::1]:53"`,
`"/tmp/app.sock"`), matching `std`. Accessors like `local_addr!` and
`peer_addr!` return strings, which lets tests bind port 0 and discover the
port. A structured `SocketAddr` type can be added later if parsing in Roc
proves common.

## Limits and timeouts

| Limit | Default | Set with |
| --- | ---: | --- |
| Live tasks | 10,000 | `ROC_NET_MAX_TASKS` |
| Open sockets | 16,384 (at most 65,535) | `ROC_NET_MAX_SOCKETS` |
| Single read | 64 KiB | – |
| Read/write timeout | none | `set_read_timeout!`, `set_write_timeout!` |
| Connect timeout | 30 s | `connect_timeout!` |

The OS may impose lower limits. With a thread per task, macOS allows about
6,100 concurrent tasks (6,144 threads per process), which is where the
benchmark's `hold_10000` scenario tops out. Limits are read at startup, and
an invalid value is reported and replaced by the default.

## Targets

macOS (arm64, x64) and Linux musl (arm64, x64). Windows is out of scope until
there is demand: Unix sockets and signal handling differ, and the template's
linker inputs don't cover it.

## Non-goals

- An HTTP server framework (use basic-webserver) or a routing/middleware stack.
- A global mutable application state service. Shared state goes through
  channels or an external store.
- Raw IP sockets and packet capture. These need privileges and
  platform-specific APIs; reconsider on demand.
- ICMP, for now. Unprivileged "datagram" ICMP sockets make a real ping
  possible without root (macOS allows them; Linux does if
  `net.ipv4.ping_group_range` includes the user's group), but Rust's standard
  library can't create them, so they need libc (the `libc` crate, `socket2`,
  or hand-written declarations). The host currently depends on nothing but
  `std` and declares no libc functions; adding ICMP means deciding to give
  that up. `examples/tcp_ping` covers most uses meanwhile.

## Milestones

1. **TCP basics (done).** Blocking listen/accept/connect/read/write/close with
   string errors and an echo server/client.
2. **Solid TCP (done).** `IOErr`, read/write/connect timeouts, `shutdown!`,
   addresses, `set_nodelay!`, and `examples/tcp_tests` (now `net_tests`, `just test`), which
   runs servers and clients together in one process.
3. **Tasks (done).** `Task.spawn!` on OS threads. A concurrent echo server and a
   TCP proxy (two tasks per connection pair). Validates cross-thread closures.
4. **Unix + UDP (done).** `Unix` streams sharing the stream methods (a
   listener deletes its socket file when it closes, and `listen!` replaces a
   leftover file nothing is listening on); `Udp` datagrams with connect,
   timeouts, broadcast, and multicast. Unix datagram sockets are deferred.
5. **Framing + Bytes (done).** Pure Roc, in the platform. A `Framing.Reader`
   wraps any stream and is passed along by value: each read returns the
   result and the updated reader, `(line, $reader) = $reader.read_line!()?`,
   which costs no more lines than a mutable reader would. `each_line!` /
   `each_frame!` run the usual loop and treat a clean end of stream as
   success; `fold_lines!` / `fold_frames!` carry state between messages,
   since a closure can't reassign a `var` outside it. Readers have a length
   limit (1 MiB by default). `Bytes` encodes and decodes 16/32/64-bit
   integers in both byte orders. Example: `examples/line_server`. Moving
   `Bytes` and `Framing` into a separate package that other platforms could
   share is possible later.
6. **ARC handles (done).** Automatic close, bounded socket heap.
7. **Channels (done)**, with `examples/chat_server`. Stress-tested with 8
   producers and 4 consumers moving 4 million heap strings: every byte
   accounted for, peak memory 3.9 MB, about a million messages per second.
8. **TLS (done).** rustls with the `aws-lc-rs` provider (chosen over `ring`:
   no `libc` crate, actively developed, post-quantum key exchange) and
   Mozilla's roots from `webpki-roots` (the macOS keychain would need Apple's
   Security framework, which Roc's linker may not support). Streams stay
   full-duplex: rustls sits behind a lock held only to encrypt or decrypt,
   with separate read and write locks keeping ciphertext and records in
   order, taken in a fixed order. Clients finish the handshake in
   `connect!`, so certificate errors surface there; servers handshake on
   first use, in the connection's own task. Releasing a stream sends
   close_notify. `ignore_unexpected_eof!` opts out of treating a missing
   close_notify as an error, like OpenSSL's `SSL_OP_IGNORE_UNEXPECTED_EOF`.
   STARTTLS (`wrap_client!` / `wrap_server!`) duplicates the TCP connection's
   handle, so the plain stream must not be used afterwards. Linux builds
   cross-compile AWS-LC with Zig (`scripts/zig-cc`). Programs using TLS are
   about 3.4 MB.
9. **Coroutine scheduler**, when more concurrent connections are needed.

`Dns.resolve!` and `Time` (done) were not milestones of their own; they were
added for `examples/tcp_ping`, which resolves once and then times TCP
handshakes. `connect!` and `listen!` also resolve names implicitly, and UDP's
`send_to!` can too.

### Example apps

These are protocols written in Roc on top of the platform, not platform
features. They test whether roc-net is pleasant to use.

- **DNS client (done: `examples/dns_client`).** Queries any record type
  against a chosen server, which the OS resolver behind `Dns.resolve!` cannot
  do. Pure encoding and decoding (`Dns.roc`, with name compression and loop
  protection, tested by `expect`) plus UDP with retries, reply validation, and
  fallback to TCP for truncated replies. It surfaced three platform gaps,
  since closed: random numbers (`Random`, for the query ID), a clock
  (`Time`), and `Bytes` readers at arbitrary offsets (`u16_be_at`, ...),
  which DNS name compression needs. Switching the parser to the offset
  readers removed its private byte helpers and error-conversion blocks.
- **Chat server (done: `examples/chat_server`).** A hub task owns the user
  list and does all broadcasting; each connection has a reader task sending
  events to the hub and a writer task draining its own outbox. The hub uses
  `try_send!`, so a user who stops reading misses messages instead of
  stalling the room.

## Linux targets and testing

Two Linux builds: `arm64musl`, static, runs anywhere; and `arm64glibc`,
dynamically linked against glibc 2.28+ (Rocky/RHEL 8 and newer). The glibc
build matters for a networking platform because a static musl binary uses
musl's own resolver and ignores `/etc/nsswitch.conf`, bypassing SSSD/LDAP host
lookups, systemd-resolved, and mDNS; with glibc, `Dns.resolve!` and
`connect!("host:port")` resolve like every other program on the machine. It
also picks up the distribution's glibc fixes, and avoids musl's allocator,
which is known to be slow under multithreaded contention.

Roc refuses to link glibc programs except on Linux, so `just build-linux
arm64glibc` cross-builds the host library on macOS (Rust's
`aarch64-unknown-linux-gnu`, AWS-LC via `zig cc -target
aarch64-linux-gnu.2.28`), then runs Roc's Linux release (a static binary) in a
Rocky 8 container. The link inputs (startup files, `libc.so.6`,
`libpthread.so.0` and the other pre-2.34 split libraries, `libgcc_s.so.1` for
Rust's unwinder) are copied from Rocky 8 by `scripts/fetch_glibc_inputs.sh`,
so symbol versions are no newer than 2.28.

`just linux-test` runs the suite (musl on Alpine; glibc on Rocky 8 and 9) and
`tests/e2e`, whose client reaches the example servers, each in its own
container, by service name through Docker's DNS (all-musl on Alpine, all-glibc
on Rocky 9). Its first run found a real bug: the host built the argument list
with `std::env::args()`, which is empty on musl (std fills it from a startup
hook glibc feeds argc/argv to and musl doesn't), so every musl program ran
without arguments; the host now reads `main`'s own argc/argv. Cross-building
also needed `zig cc` run with `-fno-sanitize=undefined`: its default UBSan
checks call a runtime that isn't linked into Roc programs. SIGPIPE behavior
was confirmed on Linux too.

The template's `ci/runtime.py fetch` can't run here, since it fingerprints
release tooling (GitHub workflows) this repo removed;
`scripts/fetch_linux_runtime.py` does the same download checked against the
same pinned SHA-256.

All four builds (`arm64musl`, `arm64glibc`, `x64musl`, `x64glibc`) run in
`just linux-test`; on an Apple Silicon Mac the x86-64 ones run under
emulation. That needs Rosetta (Colima: `--vz-rosetta`), not QEMU: Roc's
default x86-64 targets use modern-CPU instructions (AVX2), and under Colima's
QEMU those builds corrupted memory and QEMU itself crashed, while the same
code built for baseline CPUs (`x64v1musl`) ran correctly. Rosetta on macOS 15+
handles AVX2, and every stage passes under it.

## Risks and open questions

- **Cross-thread closures.** roc-ray passes closures to the host
  (`Box(() => msg)`) but deliberately runs them on one thread. Running them on
  several threads relies on atomic refcounts and on Roc code keeping no
  thread-local state. *Spawn experiment (2026-09-25):* `Task.spawn!` on OS
  threads passed 3,000 echo/proxy connections with random payloads of up to
  256 KiB, and 4,000 connections whose tasks captured and sliced shared heap
  values (110 KB list, 64 large strings). There were no mismatches or crashes,
  memory stayed flat, and every task thread exited. That is evidence, not
  proof; a ThreadSanitizer run would be stronger.
- **Error paths leaked explicitly-closed resources (resolved).** In the same
  experiment, a proxy task whose `Tcp.connect!` failed returned early through
  `?`, never closed the accepted client, and left that client hanging. With
  ARC handles the client is closed when the failed task's closure is dropped
  (it now sees a reset within 40 ms), and 10,000 connections without any
  `close!` left the server's file-descriptor count unchanged.
- **Glue sizing with type variables.** basic-webserver documents that
  `roc glue` sizes unresolved type variables incorrectly. Generic values that
  cross the host boundary (task results, channel payloads) should be boxed,
  and generated size assertions checked.
- **Nightly churn.** The compiler is pinned per nightly, and glue output
  changes between nightlies (this happened during the first build). Regenerate
  glue on each pin bump and keep hand-written host code thin over it.
