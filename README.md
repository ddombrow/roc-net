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
just smoke                 # echo server + client round trip
```

Recipes put `.tools/` on `PATH`. To use that `roc` in your own shell, run
`export PATH=$PWD/.tools:$PATH`.

## Platform API

- `Stdout.line!`, `Stderr.line!`, `Stdin.line!`: line-based standard I/O
- `Tcp.listen!` and `Tcp.connect!`: blocking TCP sockets
  - `Tcp.Listener`: `accept!`, `close!`
  - `Tcp.Stream`: `read!`, `write!`, `write_str!`, `close!`

Sockets are host resources held in a handle table (`src/sockets.rs`); Roc only
sees opaque `Listener`/`Stream` values. Close them explicitly.

The app provides `main! : List(Str) => Try({}, [Exit(I32), ..])`.

## Examples

```bash
just run tcp_echo_concurrent 127.0.0.1:8080          # in one terminal
just run tcp_client 127.0.0.1:8080 "hello"           # in another
just run tcp_proxy 127.0.0.1:9000 127.0.0.1:8080     # proxy in front of the echo server
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

- The host calls `signal(SIGPIPE, SIG_IGN)` at startup. Roc links this library
  behind its own `main`, so Rust's usual startup (which does this) never runs,
  and a write to a disconnected peer would otherwise kill the process.
- `Tcp.Stream.read!` caps a single read at 64 KiB regardless of the requested maximum.
