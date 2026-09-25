# Run `just` to list recipes.

# Use the project-local compiler installed by `just setup`.
export PATH := justfile_directory() / ".tools" + ":" + env("PATH")

# The Roc nightly pinned in the platform header.
nightly := `sed -n 's/.*roc: "\(nightly-[^"]*\)".*/\1/p' platform/main.roc`
nightly_suffix := trim_start_match(nightly, "nightly-")
nightly_os := if os() == "macos" {
    if arch() == "aarch64" { "macos_apple_silicon" } else { "macos_x86_64" }
} else {
    if arch() == "aarch64" { "linux_arm64" } else { "linux_x86_64" }
}
glue := ".tools/roc_nightly-source-" + nightly_suffix + "/src/glue/src/RustGlue.roc"
bin_dir := "target/examples"

default:
    @just --list

# Download the pinned Roc nightly (and its source, for glue) into .tools/
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .tools && cd .tools
    if [ -x roc ] && roc version | grep -q "{{nightly}}"; then
        echo "roc {{nightly}} already installed"
        exit 0
    fi
    gh release download "{{nightly}}" -R roc-lang/nightlies --clobber \
        -p "roc_nightly-{{nightly_os}}-{{nightly_suffix}}.tar.gz" \
        -p "roc_nightly-source-{{nightly_suffix}}.tar.gz"
    tar xzf "roc_nightly-{{nightly_os}}-{{nightly_suffix}}.tar.gz"
    tar xzf "roc_nightly-source-{{nightly_suffix}}.tar.gz"
    ln -sf "roc_nightly-{{nightly_os}}-{{nightly_suffix}}/roc" roc
    roc version

# Build the Rust host for the native target
build:
    ./build.sh

# Build the Rust host for every supported target
build-all:
    ./build.sh --all

# Regenerate src/roc_platform_abi.rs after changing hosted or provided functions
glue:
    roc glue {{glue}} ./src/ platform/main.roc

# List the examples
examples:
    @ls examples

# Type-check every example (or just one)
check example="":
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    for dir in examples/{{ if example == "" { "*" } else { example } }}/; do
        if roc check "$dir/main.roc" >/dev/null 2>&1; then
            echo "ok    $dir"
        else
            echo "FAIL  $dir"
            roc check "$dir/main.roc"
            status=1
        fi
    done
    exit $status

# Build the host, then run an example: just run tcp_client 127.0.0.1:8080 hi
run example *args: build
    roc examples/{{example}}/main.roc -- {{args}}

# Build an example to target/examples/<name>
build-example example: build
    @mkdir -p {{bin_dir}}
    roc build examples/{{example}}/main.roc --output={{bin_dir}}/{{example}}

# Build every example to target/examples/ (catches link errors that `check` can't)
build-examples: build
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p {{bin_dir}}
    status=0
    for dir in examples/*/; do
        name=$(basename "$dir")
        out=$(roc build "$dir/main.roc" --output={{bin_dir}}/$name 2>&1)
        # roc exits 2 when the build succeeded with warnings.
        case $? in
            0) echo "ok    $name" ;;
            2) echo "warn  $name" ;;
            *) echo "FAIL  $name"; echo "$out" | tail -15; status=1 ;;
        esac
    done
    exit $status

# Start the concurrent echo server and check that a client gets its message back
smoke: build (build-example "tcp_echo_concurrent") (build-example "tcp_client")
    #!/usr/bin/env bash
    set -euo pipefail
    {{bin_dir}}/tcp_echo_concurrent 127.0.0.1:9471 >/dev/null &
    server=$!
    trap 'kill $server 2>/dev/null' EXIT
    sleep 0.5
    reply=$({{bin_dir}}/tcp_client 127.0.0.1:9471 "smoke test")
    echo "$reply"
    [ "$reply" = "Received: smoke test" ]

# Generate API docs from the platform's doc comments into target/docs/
docs:
    roc docs platform/main.roc --output=target/docs --no-cache
    @echo "Open target/docs/index.html"

# Remove build output (keeps .tools/)
clean:
    cargo clean
    rm -rf platform/targets/*/libhost.a
