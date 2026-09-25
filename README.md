# roc-net

A [Roc](https://www.roc-lang.org/) platform for networking services, with a host written in Rust.

Started from [roc-platform-template-rust](https://github.com/lukewilliamboswell/roc-platform-template-rust).

## Requirements

- [Rust](https://rustup.rs/) (the toolchain is pinned in `rust-toolchain.toml`)
- Roc `nightly-2026-09-24-f45bfbe`, the compiler pinned in `platform/main.roc`

To install that nightly into the gitignored `.tools/` directory:

```bash
mkdir -p .tools && cd .tools
gh release download nightly-2026-09-24-f45bfbe -R roc-lang/nightlies \
  -p 'roc_nightly-macos_apple_silicon-*' -p 'roc_nightly-source-*.tar.gz'
for f in *.tar.gz; do tar xzf "$f"; done
ln -sf roc_nightly-macos_apple_silicon-2026-09-24-f45bfbe/roc roc
cd .. && export PATH=$PWD/.tools:$PATH
```

The source archive provides `RustGlue.roc`, which you need to regenerate glue.

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
./build.sh                                    # build platform/targets/<native>/libhost.a
roc examples/hello_world/main.roc

roc build examples/tcp_echo_server/main.roc --output=.tools/tcp_echo_server
.tools/tcp_echo_server 127.0.0.1:8080         # optional 2nd arg: exit after N connections
roc examples/tcp_client/main.roc -- 127.0.0.1:8080 "hello"
```

## Adding a hosted effect

1. Declare it in `platform/Host.roc` and map a `roc_*` symbol to it in the
   `hosted` block of `platform/main.roc`.
2. Wrap it in a public module (e.g. `platform/Tcp.roc`) and add that module to `exposes`.
3. Regenerate the ABI bindings:
   ```bash
   roc glue .tools/roc_nightly-source-2026-09-24-f45bfbe/src/glue/src/RustGlue.roc ./src/ platform/main.roc
   ```
4. Implement the `#[no_mangle] pub extern "C" fn roc_*` in `src/lib.rs`, following
   the ownership notes in the generated doc comment for that symbol.
5. `./build.sh`

## Notes

- The host calls `signal(SIGPIPE, SIG_IGN)` at startup. Roc links this library
  behind its own `main`, so Rust's usual startup (which does this) never runs,
  and a write to a disconnected peer would otherwise kill the process.
- `Tcp.Stream.read!` caps a single read at 64 KiB regardless of the requested maximum.
