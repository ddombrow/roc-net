#!/bin/sh
# Linux benchmark, run in a container by `just bench-linux`: roc-net's echo
# server built for musl and for glibc, and the plain-Rust thread-per-
# connection and Tokio servers built for both, with the load generator in
# the same container. Reports server CPU per operation, read from /proc.
set -u
cd /work
loadgen=bench/target-linux/aarch64-unknown-linux-musl/release/loadgen
hz=$(getconf CLK_TCK)
port=22000
run() {
    label=$1 server=$2
    for scenario in "pingpong --conns 1" "pingpong --conns 64" "bulk --conns 16" "churn --conns 32"; do
        port=$((port + 1))
        $server 127.0.0.1:$port >/dev/null 2>&1 &
        pid=$!
        sleep 0.3
        out=$($loadgen 127.0.0.1:$port $scenario --secs 4)
        ticks=$(awk '{print $14 + $15}' /proc/$pid/stat)
        kill $pid; wait $pid 2>/dev/null
        ops=$(echo "$out" | sed -E 's/.*"ops": ([0-9.]+).*/\1/')
        rate=$(echo "$out" | sed -E 's/.*"(requests_per_sec|mib_per_sec|conns_per_sec)": ([0-9.]+).*/\2/')
        awk -v l="$label" -v s="$scenario" -v t=$ticks -v hz=$hz -v o=$ops -v r=$rate \
            'BEGIN { printf "%-18s %-22s rate=%-10s cpu_us_per_op=%.2f\n", l, s, r, t / hz * 1e6 / o }'
    done
}
run "roc musl" target/linux/arm64musl/roc-echo
run "roc glibc" target/linux/arm64glibc/roc-echo
run "rust-threads musl" bench/target-linux/aarch64-unknown-linux-musl/release/echo-threads
run "rust-threads glibc" bench/target-linux/aarch64-unknown-linux-gnu/release/echo-threads
run "tokio musl" bench/target-linux/aarch64-unknown-linux-musl/release/echo-tokio
run "tokio glibc" bench/target-linux/aarch64-unknown-linux-gnu/release/echo-tokio
