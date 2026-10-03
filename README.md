# roc-net

A [Roc](https://www.roc-lang.org/) platform for networking services, with a host written in Rust.

Write custom TCP, UDP and Unix-socket protocols, servers, clients and
proxies as ordinary sequential Roc code: connect, read, write, and
`Task.spawn!` a task per connection. Tasks are lightweight coroutines, so a
server can hold tens of thousands of connections; there's TLS (rustls),
framing helpers for line- and length-delimited protocols, channels between
tasks, DNS, and timeouts on everything.

Started from [roc-platform-template-rust](https://github.com/lukewilliamboswell/roc-platform-template-rust).

## Using roc-net

Each [release](https://gitlab.com/ddombrow/roc-net/-/releases) lists the
platform's URL and the Roc nightly it's built for. Use them in your app's
header:

```roc
app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "<release URL>" }

import pf.Stdout
import pf.Tcp

main! : List(Str) => Try({}, _)
main! = |_args| {
	stream = Tcp.connect!("example.com:80")?
	stream.write_str!("HEAD / HTTP/1.0\r\nHost: example.com\r\n\r\n")?
	reply = stream.read!(4096)?
	Stdout.line!(Str.from_utf8_lossy(reply))
}
```

Roc's new compiler changes quickly, and a release works with exactly the
nightly it names. Released bundles build for macOS (arm64, x86-64) and
static Linux (musl: arm64, x86-64; the programs run on any distribution).
The glibc Linux targets need a build from source (see below).

The API is summarized under [Platform API](#platform-api); `examples/` has
complete programs, and `just docs` builds the full reference.

### Known limitations

- **Pre-1.0**: the API will change between releases.
- **Cooperative scheduling**: a task yields when it waits and every 128
  socket operations, but a long pure computation holds its worker thread
  (and the other tasks on it) until it finishes, unless it calls
  `Task.yield!` now and then.
- **Cooperative cancellation**: `cancel!` ends a task's waits with
  `Cancelled`, which `?` passes up; a task that ignores the error, or
  computes without waiting, keeps going (it can check `Task.is_cancelled!`).
- **Fixed task stacks**: 256 KiB each (`ROC_NET_TASK_STACK_KIB`); deeper
  recursion crashes the program. `main!` gets 8 MiB.
- **Linux task ceiling**: each task's stack is two memory mappings, so the
  default `vm.max_map_count` (65,530) allows roughly 30,000 tasks.
- **macOS isn't tested in CI** (no free macOS runners); releases are tested
  on it by hand.
- **No HTTP**: roc-net is for custom protocols. For HTTP services, see
  basic-webserver.

## Development

### Requirements

- [Rust](https://rustup.rs/) (the toolchain is pinned in `rust-toolchain.toml`)
- [Zig](https://ziglang.org), only for Linux builds (`just build-all`,
  `just linux-test`): it cross-compiles the host's C dependency (AWS-LC, used by TLS)
- Docker with Compose, only for `just linux-test`. On an Apple Silicon Mac the
  x86-64 builds run under emulation, which must be Rosetta (Colima:
  `colima start --vz-rosetta`); QEMU mis-runs Roc's default x86-64 code.
- Roc `nightly-2026-09-29-7f11a82`, the compiler pinned in `platform/main.roc`

Common tasks use [just](https://github.com/casey/just). Run `just` to list them.

```bash
just setup                 # download the pinned nightly into .tools/ (needs gh)
just build                 # build the Rust host
just check                 # type-check every example
just build-examples        # build every example into target/examples/
just run hello_world       # run an example
just test                  # TCP/Unix/UDP tests (examples/net_tests) + smoke test
just smoke                 # echo server + client round trip
just docs                  # API reference in target/docs/index.html
just linux-test            # suite + e2e for arm64/x64 Linux: musl on Alpine, glibc on Rocky 8/9 (needs docker)
```

`scripts/install_roc.sh` (what `just setup` runs) and `scripts/install_zig.sh`
install tools from public downloads, so CI needs no credentials.

### CI

`.gitlab-ci.yml` builds and tests every Linux target on GitLab's native arm64
and x86-64 runners: type-check the examples; build the host and link the musl
programs; link the glibc programs on Rocky 8; then run the test suite (musl on
Alpine, glibc on Rocky 8 and 9) and the e2e checks. Pipelines run for merge
requests, pushes to the default branch, and manual runs. macOS isn't covered
(no free macOS runners); `just test` covers it locally.

Recipes put `.tools/` on `PATH`. To use that `roc` in your own shell, run
`export PATH=$PWD/.tools:$PATH`.

## Platform API

Full reference: run `just docs` and open `target/docs/index.html`. In brief:

- `Stdout.line!`, `Stderr.line!`, `Stdin.line!`: line-based standard I/O;
  `Stdin.read_line!` tells an empty line (`Line("")`) from the end of input;
  `Select`'s `on_stdin_line` waits for a line alongside anything else
  (`End`)
- `Log.info!(message, fields)` (and `debug!`, `warn!`, `error!`): structured
  log lines on stderr, with a wall-clock timestamp, the level and the task,
  as text or JSON (`ROC_NET_LOG_FORMAT`), filtered by `ROC_NET_LOG`. Logging
  never waits: a thread of its own writes the lines, so a slow or stalled
  stderr can't stall a server (past about 1 MiB waiting, the oldest lines
  are dropped, and counted; raise `ROC_NET_LOG_BUFFER_KIB` if bursts hit
  that). Use it rather than `Stderr.line!` in servers.
- `Tcp.listen!`, `Tcp.listen_with!`, `Tcp.connect!`, `Tcp.connect_timeout!`, `Tcp.connect_with!`: blocking TCP sockets
  - Accepted streams get 60-second idle (read) and write timeouts, so a
    client that goes quiet or stops reading can't hold a server task forever;
    `Tcp.listen_config.with_idle_timeout(...)`, `.with_write_timeout(...)`
    change them (also for `Unix`, and `Tls.server_config`); `.with_backlog(n)`
    and `.with_reuse_port(True)` (`SO_REUSEPORT`) set up the listening socket
  - `Tcp.connect_config.with_local_address(...)`, `.with_interface("eth1")`,
    `.with_timeout(...)`, for `Tcp.connect_with!`
  - `Tcp.Listener`: `accept!`, `local_addr!`, `close!` (stop taking
    connections now, for a server shutting down; also on `Unix` and `Tls`)
  - `Tcp.Stream`: `read!`, `read_into!`, `read_append!`, `write!`, `write_str!`, `shutdown!`, `close!`,
    `set_read_timeout!`, `set_write_timeout!`, `set_nodelay!`, `set_keepalive!`,
    `set_recv_buffer_size!`, `set_send_buffer_size!` (and getters), `local_addr!`, `peer_addr!`
  - `read_into!(buf, max)` reuses `buf`'s memory for what arrives (no new
    allocation per read when nothing else holds `buf`); `read_append!` adds
    to it instead (`Framing` reads this way). Also on `Unix` and `Tls` streams.
  - Errors are `TcpErr(IOErr)`, so you can match specific cases such as
    `Err(TcpErr(ConnectionRefused))` or `Err(TcpErr(TimedOut))`.
- `Unix.listen!`, `Unix.connect!` (`connect_timeout!`): Unix domain stream sockets on a file path
  - `Unix.Listener`: `accept!`, `local_addr!`; deletes its socket file when it closes
  - `Unix.Stream`: the same methods as `Tcp.Stream` except `set_nodelay!` and
    `set_keepalive!`, plus `peer_credentials!` (the peer's user, group and
    process ids)
  - Errors are `UnixErr(IOErr)`.
- `Tls.connect!`, `Tls.connect_with!`, `Tls.listen!`: TLS over TCP (rustls)
  - `Tls.Stream`: the same methods as `Tcp.Stream`, plus `ignore_unexpected_eof!`
    and `handshake!` (a server stream otherwise finishes its handshake on its
    first read or write; call it before sharing the stream between tasks),
    `server_name!` (the name the client asked for, SNI), `alpn_protocol!`,
    `peer_certificates!` and `peer_certificate_valid_for!(name)` (who's at
    the other end), and `abort!` (also on `Tcp` and `Unix` streams: end a connection with a
    reset rather than cleanly, on error paths)
  - `Tls.client_config.with_ca_file(...)`, `.with_server_name(...)`, `.with_alpn(...)`, `.with_timeout(...)`,
    `.with_client_cert({ cert_file, key_file })`
  - `Tls.server_config({ cert_file, key_file })`, `.with_handshake_timeout(...)`:
    clients get 10 seconds by default to finish the handshake, a deadline a
    slowloris client can't stretch
  - `.with_cert_for("api.example.com", { cert_file, key_file })`: a
    certificate per host name (`*.` wildcards too) on one listener, chosen by
    SNI; the one from `server_config` is for every other name.
    `.with_alpn(["h2", "http/1.1"])` for application protocols
  - Mutual TLS: `.with_client_auth("clients-ca.pem", Required)` (or
    `Optional`) asks clients for a certificate from that CA; the stream's
    `peer_certificate_valid_for!("billing.internal")` says who it's for
  - `Tls.wrap_client!`, `Tls.wrap_server!`: upgrade a TCP connection (STARTTLS)
  - Errors are `TlsErr(IOErr)`; certificate problems arrive as `TlsErr(Other(message))`,
    and so do certificate and key files that can't be loaded, naming the file.
- `Pipe.copy_both!(a, b)`: copy between two streams (any kinds) in both
  directions until both end, the core of a proxy. Half-closes are passed on,
  the first error aborts both (so a truncated response is never passed off
  as complete), the bytes never become Roc lists, idle sessions hold no
  buffers, and the session is idle only when neither direction moves. `Pipe`'s docs also
  show how to annotate code that takes any kind of stream (a `where` clause)
  and keep listeners of different kinds in one list.
- `Pipe.copy_to!(from, to, UntilEnd | Exactly(n))`: one direction, such as
  a message's body after its header; `Exactly(n)` never reads past the
  `n`th byte. After reading with a `Framing` reader, use
  `reader.copy_to!(to, limit)`, which sends the reader's buffered bytes
  first and keeps anything past the limit for its next read.
- `Udp.bind!`, `Udp.bind_with!` (`Udp.bind_config.with_reuse_port(True)`): UDP sockets
  - `Udp.Socket`: `send_to!`, `recv_from!`, `connect!`, `send!`, `recv!`,
    `set_read_timeout!`, `set_write_timeout!`, `set_broadcast!`,
    `join_multicast!`, `leave_multicast!`, buffer sizes, `local_addr!`, `peer_addr!`
  - Receives say whether the datagram was cut short (`truncated`), so a
    parser never takes part of a packet for the whole
  - Errors are `UdpErr(IOErr)`.
- `Framing`: split a stream into messages
  - `each_line!`, `each_frame!`: handle every line or length-prefixed frame
    until the peer hangs up; `fold_lines!`, `fold_frames!` also carry state
    from one message to the next
  - Each line, record, or frame must arrive within 60 seconds
    (`reader.with_message_timeout(...)`), which stops a peer trickling bytes
  - A read timeout between messages fails with `Idle(reader)`, handing the
    reader back so the app can ping the peer and carry on (see `chat_server`)
  - `reader` / `reader_with_max`, then `read_line!`, `read_until!`,
    `read_exactly!`, `read_frame!`, `read_to_end!`, each returning the result and the updated
    reader: `(line, $reader) = $reader.read_line!()?`
  - `write_frame!`: write a 4-byte big-endian length, then the bytes
  - `read_parsed!(parse)` and `Select`'s `on_parsed`: a framing of your own,
    as a pure function of the buffered bytes (`Parsed(value, used)`,
    `NeedMore` or `Malformed(err)`), so a protocol package can read its
    messages (and wait for them in a `Select`) like lines and frames
- `Bytes`: encode and decode `U16`/`U32`/`U64`, big- and little-endian:
  `u32_be` to encode, `take_u32_be` to decode from the front of a list, and
  `u32_be_at` to decode at an offset; plus `take`, `take_u8`, `u8_at`, `bytes_at`;
  `to_hex` and `from_hex`
- `Cryptography`: `X25519` key agreement, `ChaChaPoly` and `AesGcm`
  encryption, `Ed25519` signatures, `HmacSha256`, `HkdfSha256`, and
  `constant_time_eq!` (from AWS-LC, the library `Tls` uses; SHA-256 is
  Roc's builtin `Crypto.SHA256`). Secret keys are opaque.
- `Noise`: the Noise Protocol Framework (rev 34), checked against the
  cacophony test vectors. `Noise.handshake!(stream, config, payloads)` runs
  a handshake (`XX`, `IK`, `NK`, ... with pre-shared keys) over a TCP or
  Unix stream and gives back a `Noise.Stream`, which has the same methods
  as `Tcp.Stream` (so `Framing` works over it). Underneath, the spec's own
  sans-I/O `Handshake` and `CipherState`, for protocols that carry
  handshake messages their own way (`CipherState.with_nonce` for transports
  that lose or reorder messages).
- `File`: whole files. `read_bytes!`, `read_utf8!`, `write_bytes!`,
  `write_utf8!`, `append_bytes!`, `append_utf8!`, `rename!`, `delete!`,
  `exists!`; `write_new!(path, bytes, 0o600)` creates a file only if it's
  absent (for a secret key), and `write_atomic!` replaces one so readers see
  the old contents or the new, never part. Calls run on helper threads, so
  a slow disk doesn't stall other tasks. Errors are `FileErr(IOErr)`.
- `Env.var!(name)`: an environment variable, or `VarNotFound(name)`
- `Signal.catch!([Terminate, Interrupt])`, then `Signal.next!` or `Select`'s
  `on_signal` arm: SIGINT, SIGTERM, SIGHUP, SIGUSR1 and SIGUSR2, for
  stopping cleanly or reloading
- `Random`: `u8!()` ... `u64!()`, `between!(low, high)`, and `bytes!(n)`
  (up to 16 MiB, returning a `Try`), cryptographically secure
- `Time`: `now!` (monotonic `Instant`), `instant.elapsed!()`, `sleep!`, and
  `Duration`s (`Time.millis(500)`, `.to_micros()`, ...); `utc_now!` for the
  wall clock (`Utc`: `.to_rfc3339()`, `.to_millis_since_epoch()`, ...)
- `Dns.resolve!`, `Dns.resolve_timeout!`: a host name's IP addresses, from the
  OS resolver. Connect timeouts include the name lookup.
- `Task.spawn!`: run a closure concurrently, as a lightweight task. Returns a
  `Handle`: `join!` waits for the task's result, `cancel!` stops it.
  Cancelling is cooperative: the task's waits end with a `Cancelled` error,
  which `?` passes up, so it unwinds and its sockets close.
  - `Task.scope!(|scope| ...)`: tasks started with `scope.spawn!` can't
    outlive the scope. It waits for them when the body succeeds and cancels
    them first when it fails. A task in the scope failing doesn't stop the
    others; see `Task.scope!`'s docs for stopping them all.
    `scope.cancel_all!()` cancels them from inside the body, for helper
    tasks that should last only as long as it.
  - `Task.yield!`, `Task.is_cancelled!`: for long computations, which
    otherwise hold their thread
- `Select`: wait for whichever happens first, with an arm for each thing and
  a callback turning it into your own value:
  ```roc
  next = Select.new({})
      .on_line(reader, |result| FromPeer(result))
      .on_receive(outbox, |result| ToSend(result))
      .on_timeout(Time.seconds(30), || Idle)
      .wait!()?
  ```
  Arms: `on_read`, `on_accept`, `on_line`, `on_frame` (Framing readers),
  `on_receive`, `on_send`, `on_join` (a task finishing), `on_stdin_line`,
  `on_timeout`, over any kind of stream (`Tcp`, `Tls`, `Unix`, `Noise`).
  Only the winning arm consumes anything, and ready arms take turns.
- `Channel.new!(capacity)`: a bounded queue between tasks, returning
  `(sender, receiver)`: `send!`, `try_send!`, `close!`; `receive!`,
  `try_receive!`, `receive_timeout!`. Closes when an end is released.

Sockets close automatically when Roc drops the last reference to them, including
when a task ends early on an error. `Stream.close!` is only for closing early,
for example to wake a task blocked reading the same stream. Handles are Roc
`Box(U64)` values whose memory is a slot in a host-owned heap
(`src/resource.rs`); `roc_dealloc` recognizes those slots and closes the socket.

The app provides `main! : List(Str) => Try({}, [Exit(I32), ..])`.

### Limits

`ROC_NET_MAX_TASKS` (default 100,000) caps concurrent tasks, and
`ROC_NET_MAX_SOCKETS` (default 16,384) caps open sockets. At the task limit
`Task.spawn!` fails; a server should ignore that error to drop the one
connection rather than stop (`_ = Task.spawn!(|| handle!(stream))`). At the
socket limit `accept!` waits for a free slot.

Tasks are coroutines, many per thread: up to `ROC_NET_WORKERS` threads
(default one per CPU) run them, started as load needs them, and a task
waiting on a socket, a channel or a sleep costs its stack, not a thread. A
thread that stays busy shares its backlog with idle ones (work stealing,
after `ROC_NET_SHARE_AFTER_US`, default 500). Each task's stack is `ROC_NET_TASK_STACK_KIB`
(default 256) of address space, of which it uses only what it touches;
deeper recursion than that crashes the program. On Linux each stack is two
memory mappings, so the default `vm.max_map_count` (65,530) allows roughly
30,000 tasks unless it's raised. Scheduling is cooperative: a task yields
when it waits and every 128 socket operations, but a long pure computation
holds its thread until it finishes.

## Packages

Protocols are built as Roc packages on the platform, not inside it (see
the boundary in `docs/roadmap.md`). This repo has some, in `packages/`,
each released and versioned on its own as a bundle at
`https://gitlab.com/api/v4/projects/86936101/packages/generic/NAME/VERSION/<hash>.tar.zst`
(roc reads the version from the URL):

- `protobuf`: the Protocol Buffers wire format, pure Roc (no platform)
- `resp`: the Redis serialization protocol (RESP2 and RESP3), and a client

```roc
app [main!] {
    pf: platform "https://gitlab.com/.../roc-net/0.7.0/<hash>.tar.zst",
    resp: "https://gitlab.com/.../resp/0.1.0/<hash>.tar.zst",
}
```

Each has a README and CHANGELOG in its directory. `just test` runs their
tests; `just bundle-package NAME VERSION` builds and checks one's bundle,
and `just release-package NAME VERSION` publishes it.

## Examples

```bash
just run tcp_echo_concurrent 127.0.0.1:8080          # in one terminal
just run tcp_client 127.0.0.1:8080 "hello"           # in another
just run tcp_proxy 127.0.0.1:9000 127.0.0.1:8080     # proxy in front of the echo server
just run tls_proxy 127.0.0.1:9080 127.0.0.1:9443 \
    examples/net_tests/certs/server.pem examples/net_tests/certs/server-key.pem \
    127.0.0.1:8080 localhost=127.0.0.1:8081           # terminate TLS, route by SNI name
just run noise_chat listen 127.0.0.1:7000 ada         # an encrypted 1:1 chat over Noise, remembering keys; then, elsewhere:
just run noise_chat connect 127.0.0.1:7000 grace
just run graceful_server 127.0.0.1:8080              # drains on SIGTERM or Ctrl-C (try SLOW 5000 first)
just run retry_backoff 127.0.0.1:8080 hello          # retries with backoff until a line server is up
just run connection_pool 127.0.0.1:8080              # 100 requests through a pool of 4 connections

just run udp_echo_server 127.0.0.1:8081
just run udp_client 127.0.0.1:8081 "hello"

just run line_server 127.0.0.1:8082                   # then: nc 127.0.0.1 8082, type "ADD 2 40"

just run chat_server 127.0.0.1:8083                   # then nc 127.0.0.1 8083 from a few terminals
just run first_to_answer example.com:443 example.org:443   # connect to all at once; first wins, rest cancelled
just run https_get https://example.com/               # a tiny curl over TLS
just run dns_client gmail.com MX                      # a small dig: any record type, any server
just run tcp_ping example.com 443 -c 4                # ping, timing TCP handshakes instead of ICMP

just run unix_echo_server /tmp/echo.sock
just run unix_client /tmp/echo.sock "hello"
```

## Adding a hosted effect

1. Declare it in `platform/Host.roc` and map a `roc_*` symbol to it in the
   `hosted` block of `platform/main.roc`.
2. Wrap it in a public module (e.g. `platform/Tcp.roc`) and add that module to `exposes`.
3. Regenerate the ABI bindings: `just glue`
4. Implement the `#[no_mangle] pub extern "C" fn roc_*` in `src/lib.rs`, following
   the ownership notes in the generated doc comment for that symbol.
5. `just build`, then `just build-examples`

## Notes

- Writing to a peer that has disconnected returns `BrokenPipe` rather than
  killing the process with SIGPIPE. Rust's standard library arranges this for
  every socket it creates (`SO_NOSIGPIPE` on macOS, `MSG_NOSIGNAL` on Linux),
  so the host doesn't touch signal handling. Stdout and stderr keep the
  default, so `app | head` exits quietly like other command-line tools.
  The one exception is `Log`'s writer thread, which blocks SIGPIPE for
  itself only, so a closed log pipe loses the lines rather than ending the
  program.
- Platform Roc code must never `Box.unbox` or re-box a socket handle. The
  compiler can reuse an unboxed box's memory in place, which would bypass
  `roc_dealloc` and leak the socket.
- The host depends on `rustls` (with the `aws-lc-rs` crypto provider, which
  bundles AWS-LC's C code) and `webpki-roots` (Mozilla's root certificates).
  `Random` uses the same provider's secure random generator.
- TLS tests use `examples/net_tests/certs`, made by `scripts/make_test_certs.sh`.
- Linux has two builds. `arm64musl` is static and runs on any distribution.
  `arm64glibc` links dynamically against the system's glibc (2.28 or newer:
  Rocky/RHEL 8+, Debian 10+, Ubuntu 20.04+), so name lookups go through the
  system's resolver configuration (NSS), like other programs on the machine.
  `just build-linux [arm64musl|arm64glibc]` builds the test programs into
  `target/linux/<target>`. Roc only links glibc programs on Linux, so the
  glibc build runs Roc's Linux release in a Rocky 8 container, against glibc
  files `scripts/fetch_glibc_inputs.sh` copies out of Rocky 8.
- `just linux-test` builds all four Linux targets (arm64 and x64, musl and
  glibc) and runs `examples/net_tests` (musl on Alpine; glibc on Rocky 8 and 9)
  and `tests/e2e`, which reaches the example servers, each in its own
  container, by service name (`tests/e2e/compose.yaml`; all-musl on Alpine,
  all-glibc on Rocky 9). The musl C runtime comes from the release pinned in
  `runtime/link-inputs.lock.json`, checked against its SHA-256 by
  `scripts/fetch_linux_runtime.py`.
- `Tcp.Stream.read!` caps a single read at 64 KiB regardless of the requested maximum.
