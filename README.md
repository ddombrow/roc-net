# roc-net

A [Roc](https://www.roc-lang.org/) platform for networking services, with a host written in Rust.

Started from [roc-platform-template-rust](https://github.com/lukewilliamboswell/roc-platform-template-rust).

## Requirements

- [Rust](https://rustup.rs/) (the toolchain is pinned in `rust-toolchain.toml`)
- Roc `nightly-2026-09-24-f45bfbe`, the compiler pinned in `platform/main.roc`

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
```

Recipes put `.tools/` on `PATH`. To use that `roc` in your own shell, run
`export PATH=$PWD/.tools:$PATH`.

## Platform API

Full reference: run `just docs` and open `target/docs/index.html`. In brief:

- `Stdout.line!`, `Stderr.line!`, `Stdin.line!`: line-based standard I/O
- `Tcp.listen!`, `Tcp.connect!`, `Tcp.connect_timeout!`: blocking TCP sockets
  - `Tcp.Listener`: `accept!`, `local_addr!`
  - `Tcp.Stream`: `read!`, `write!`, `write_str!`, `shutdown!`, `close!`,
    `set_read_timeout!`, `set_write_timeout!`, `set_nodelay!`, `local_addr!`, `peer_addr!`
  - Errors are `TcpErr(IOErr)`, so you can match specific cases such as
    `Err(TcpErr(ConnectionRefused))` or `Err(TcpErr(TimedOut))`.
- `Unix.listen!`, `Unix.connect!`: Unix domain stream sockets on a file path
  - `Unix.Listener`: `accept!`, `local_addr!`; deletes its socket file when it closes
  - `Unix.Stream`: the same methods as `Tcp.Stream` except `set_nodelay!`
  - Errors are `UnixErr(IOErr)`.
- `Udp.bind!`: UDP sockets
  - `Udp.Socket`: `send_to!`, `recv_from!`, `connect!`, `send!`, `recv!`,
    `set_read_timeout!`, `set_write_timeout!`, `set_broadcast!`,
    `join_multicast!`, `leave_multicast!`, `local_addr!`, `peer_addr!`
  - Errors are `UdpErr(IOErr)`.
- `Framing`: split a stream into messages
  - `each_line!`, `each_frame!`: handle every line or length-prefixed frame
    until the peer hangs up; `fold_lines!`, `fold_frames!` also carry state
    from one message to the next
  - `reader` / `reader_with_max`, then `read_line!`, `read_until!`,
    `read_exactly!`, `read_frame!`, each returning the result and the updated
    reader: `(line, $reader) = $reader.read_line!()?`
  - `write_frame!`: write a 4-byte big-endian length, then the bytes
- `Bytes`: encode and decode `U16`/`U32`/`U64`, big- and little-endian
  (`u32_be`, `take_u32_be`, ...), plus `take` and `take_u8`
- `Time`: `now!` (monotonic `Instant`), `instant.elapsed!()`, `sleep!`, and
  `Duration`s (`Time.millis(500)`, `.to_micros()`, ...)
- `Dns.resolve!`: a host name's IP addresses, from the OS resolver
- `Task.spawn!`: run a closure concurrently on its own thread

Sockets close automatically when Roc drops the last reference to them, including
when a task ends early on an error. `Stream.close!` is only for closing early,
for example to wake a task blocked reading the same stream. Handles are Roc
`Box(U64)` values whose memory is a slot in a host-owned heap
(`src/resource.rs`); `roc_dealloc` recognizes those slots and closes the socket.

The app provides `main! : List(Str) => Try({}, [Exit(I32), ..])`.

### Limits

`ROC_NET_MAX_TASKS` (default 10,000) caps concurrent tasks, and
`ROC_NET_MAX_SOCKETS` (default 16,384) caps open sockets. At the task limit
`Task.spawn!` fails; a server should ignore that error to drop the one
connection rather than stop (`_ = Task.spawn!(|| handle!(stream))`). At the
socket limit `accept!` waits for a free slot. Each task is an OS thread, so
the OS may allow fewer: about 6,100 on macOS.

## Examples

```bash
just run tcp_echo_concurrent 127.0.0.1:8080          # in one terminal
just run tcp_client 127.0.0.1:8080 "hello"           # in another
just run tcp_proxy 127.0.0.1:9000 127.0.0.1:8080     # proxy in front of the echo server

just run udp_echo_server 127.0.0.1:8081
just run udp_client 127.0.0.1:8081 "hello"

just run line_server 127.0.0.1:8082                   # then: nc 127.0.0.1 8082, type "ADD 2 40"

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
- Platform Roc code must never `Box.unbox` or re-box a socket handle. The
  compiler can reuse an unboxed box's memory in place, which would bypass
  `roc_dealloc` and leak the socket.
- `Tcp.Stream.read!` caps a single read at 64 KiB regardless of the requested maximum.
