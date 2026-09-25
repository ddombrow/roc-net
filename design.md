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
- Live tasks are bounded. Spawning past the limit fails with a typed error
  rather than queueing without bound.
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

**Communication between tasks** (for chat servers, pub/sub, proxies): a
bounded host `Channel` carrying boxed Roc values, with `send!`, `receive!`,
and timeouts. It is designed after spawn works, since it depends on the same
cross-thread closure and value handling.

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
Listeners have no `close!`. The heap holds 4096 sockets; past that, creating
one fails with an error.

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
| `Unix` | stream `listen!`/`connect!` (same `Stream` methods as `Tcp`), datagram sockets, filesystem paths; Linux abstract names later |
| `Dns` | `resolve!` a host name to a list of addresses |
| `Task` | `spawn!`, and later `Channel` |
| `Time` | `sleep!`, monotonic `now!`, deadlines |
| `Bytes` (pure) | big/little-endian integer encoding and decoding, slicing helpers |
| `Framing` (pure + effectful) | a buffered reader over any stream: `read_exactly!`, `read_until!`, `read_line!`, length-prefixed frames |
| `Tls` (later) | rustls client and server, producing a stream with the shared methods |
| `Stdout`, `Stderr`, `Stdin` | existing |

### Shared stream methods

Every stream type provides:

```roc
read! : s, U64 => Try(List(U8), IOErr)     # up to n bytes; [] means EOF
write! : s, List(U8) => Try({}, IOErr)     # all bytes
shutdown! : s, [Read, Write, Both] => Try({}, IOErr)
set_read_timeout! : s, [NoTimeout, Millis(U64)] => {}
set_write_timeout! : s, [NoTimeout, Millis(U64)] => {}
close! : s => {}
```

`Framing` is written against these with `where` clauses, so it covers every
current and future stream type.

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

## Limits and timeouts (initial defaults)

| Limit | Default |
| --- | ---: |
| Single read | 64 KiB |
| Open handles | 4096 |
| Live tasks | 1024 |
| Read/write timeout | none (opt in per stream) |
| Connect timeout | 30 s |

## Targets

macOS (arm64, x64) and Linux musl (arm64, x64). Windows is out of scope until
there is demand: Unix sockets and signal handling differ, and the template's
linker inputs don't cover it.

## Non-goals

- An HTTP server framework (use basic-webserver) or a routing/middleware stack.
- A global mutable application state service. Shared state goes through
  channels or an external store.
- Raw IP/ICMP sockets and packet capture. These need privileges and
  platform-specific APIs; reconsider on demand.

## Milestones

1. **TCP basics (done).** Blocking listen/accept/connect/read/write/close with
   string errors and an echo server/client.
2. **Solid TCP.** `IOErr`, timeouts, `shutdown!`, addresses, `set_nodelay!`,
   and automated tests that run server and client together.
3. **Tasks.** `Task.spawn!` on OS threads. A concurrent echo server and a
   TCP proxy (two tasks per connection pair). Validates cross-thread closures.
4. **Unix + UDP.** `Unix` streams sharing the stream methods; `Udp`
   datagrams; `Dns.resolve!`.
5. **Framing + Bytes.** A pure-Roc buffered reader and codecs, with examples:
   a line-protocol chat server and a length-prefixed RPC.
6. **ARC handles (done).** Automatic close, bounded socket heap.
7. **Channels, TLS, coroutine scheduler**, in whatever order use cases demand.

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
