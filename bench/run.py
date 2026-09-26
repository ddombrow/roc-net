#!/usr/bin/env python3
"""Benchmark roc-net's echo server against Rust baselines.

    bench/run.py [--label NAME] [--secs S] [--servers roc,threads,tokio]
    bench/run.py history [METRIC ...]

Each scenario runs against a freshly started server. Results are appended to
bench/results.csv (one row per metric, tagged with time, git commit, and
label) so runs can be compared over time.
"""

import argparse
import csv
import datetime
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BENCH = ROOT / "bench"
RESULTS = BENCH / "results.csv"
LOADGEN = BENCH / "target/release/loadgen"

SERVERS = {
    "roc": [str(ROOT / "target/bench/roc-echo")],
    "threads": [str(BENCH / "target/release/echo-threads")],
    "tokio": [str(BENCH / "target/release/echo-tokio")],
}

# (name, loadgen scenario, options). `secs` is filled in from --secs.
SCENARIOS = [
    ("pingpong_1", "pingpong", ["--conns", "1", "--size", "64"]),
    ("pingpong_64", "pingpong", ["--conns", "64", "--size", "64"]),
    ("bulk_1", "bulk", ["--conns", "1"]),
    ("bulk_16", "bulk", ["--conns", "16"]),
    ("churn_32", "churn", ["--conns", "32"]),
    ("hold_10000", "hold", ["--conns", "10000"]),
]

# Metrics shown in the summary; lower is better for latency.
LOWER_IS_BETTER = {"p50_us", "p99_us", "rss_mib", "errors", "cpu_us_per_op"}


def sh(cmd, cwd=ROOT, **kwargs):
    return subprocess.run(cmd, check=True, cwd=cwd, **kwargs)


def build():
    sh(["just", "build"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (ROOT / "target/bench").mkdir(parents=True, exist_ok=True)
    sh(["roc", "build", "bench/roc-echo/main.roc", "--output=target/bench/roc-echo"],
       stdout=subprocess.DEVNULL, env={**os.environ, "PATH": f"{ROOT / '.tools'}:{os.environ['PATH']}"})
    sh(["cargo", "build", "--release", "--quiet"], cwd=BENCH)


def git_commit():
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                            capture_output=True, text=True).stdout.strip() or "none"
    dirty = subprocess.run(["git", "status", "--porcelain", "--", "src", "platform"],
                           cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return commit + ("-dirty" if dirty else "")


def wait_for_port(port, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return True
        except OSError:
            time.sleep(0.05)
    return False


def rss_mib(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return round(int(out.strip()) / 1024, 1) if out.strip() else None


def time_wait_count():
    out = subprocess.run(["netstat", "-an", "-p", "tcp"], capture_output=True, text=True).stdout
    return out.count("TIME_WAIT")


def run_scenario(server, scenario, port, secs):
    proc = subprocess.Popen(SERVERS[server] + [f"127.0.0.1:{port}"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    metrics = {}
    try:
        metrics = measure(proc, scenario, port, secs)
    finally:
        cpu_s = stop_server(proc)
    ops = metrics.pop("ops", None)
    if cpu_s is not None and ops:
        metrics["cpu_us_per_op"] = round(cpu_s * 1e6 / ops, 2)
    return metrics


def measure(proc, scenario, port, secs):
    _, kind, options = scenario
    if not wait_for_port(port):
        return {"error": "server did not start"}
    args = [str(LOADGEN), f"127.0.0.1:{port}", kind, *options]
    if kind != "hold":
        args += ["--secs", str(secs)]
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=120)
        metrics = json.loads(out.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError) as err:
        return {"error": f"loadgen failed: {err}"}
    metrics["rss_mib"] = rss_mib(proc.pid)
    # Give a server that is shutting down a moment to finish exiting.
    time.sleep(0.2)
    metrics["server_survived"] = proc.poll() is None
    return metrics


def stop_server(proc):
    """Kill the server; return the CPU seconds it used, if it was still running."""
    if proc.poll() is not None:
        return None  # already exited and reaped; its usage is gone
    proc.kill()
    _, _, usage = os.wait4(proc.pid, 0)
    proc.returncode = -9
    return usage.ru_utime + usage.ru_stime


def fmt(value):
    if isinstance(value, bool):
        return "yes" if value else "NO"
    if isinstance(value, float):
        return f"{value:,.1f}"
    if isinstance(value, int):
        return f"{value:,}"
    return str(value)


def summarize(results, servers):
    headline = {
        "pingpong": ["requests_per_sec", "p50_us", "p99_us", "cpu_us_per_op"],
        "bulk": ["mib_per_sec", "cpu_us_per_op"],
        "churn": ["conns_per_sec", "cpu_us_per_op"],
        "hold": ["max_open_conns"],
    }
    rows = []
    for name, kind, _ in SCENARIOS:
        for metric in headline[kind] + ["rss_mib", "server_survived"]:
            values = [results[s].get(name, {}).get(metric) for s in servers]
            rows.append((f"{name} {metric}", values))
    ratios = [s for s in servers if s != "roc"] if "roc" in servers else []
    header = ["scenario / metric"] + servers + [f"roc/{s}" for s in ratios]
    table = [header]
    for label, values in rows:
        by_server = dict(zip(servers, values))
        line = [label] + [fmt(v) if v is not None else "-" for v in values]
        for other in ratios:
            a, b = by_server["roc"], by_server[other]
            numeric = isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool)
            line.append(f"{a / b:.2f}x" if numeric and b else "")
        table.append(line)
    widths = [max(len(row[i]) for row in table) for i in range(len(header))]
    for i, row in enumerate(table):
        print("  ".join(cell.ljust(w) if j == 0 else cell.rjust(w) for j, (cell, w) in enumerate(zip(row, widths))))
        if i == 0:
            print("  ".join("-" * w for w in widths))
    print("\nHigher is better for requests, MiB/s, conns/s and max_open_conns. Lower is better for")
    print("p50/p99, RSS, and cpu_us_per_op (server CPU per request, per MiB for bulk, per connection for churn).")


def record(results, label, commit):
    new_file = not RESULTS.exists()
    stamp = datetime.datetime.now().isoformat(timespec="seconds")
    with RESULTS.open("a", newline="") as f:
        writer = csv.writer(f)
        if new_file:
            writer.writerow(["time", "commit", "label", "server", "scenario", "metric", "value"])
        for server, scenarios in results.items():
            for scenario, metrics in scenarios.items():
                for metric, value in metrics.items():
                    writer.writerow([stamp, commit, label, server, scenario, metric, value])


def history(metrics):
    if not RESULTS.exists():
        sys.exit("No results yet; run bench/run.py first.")
    wanted = set(metrics) or {"requests_per_sec", "mib_per_sec", "conns_per_sec", "max_open_conns", "cpu_us_per_op"}
    runs = {}
    with RESULTS.open() as f:
        for row in csv.DictReader(f):
            if row["server"] != "roc" or row["metric"] not in wanted:
                continue
            key = (row["time"], row["commit"], row["label"])
            runs.setdefault(key, {})[f"{row['scenario']} {row['metric']}"] = row["value"]
    columns = sorted({c for values in runs.values() for c in values})
    print("roc-net results by run:\n")
    print("  ".join(["time", "commit", "label"] + columns))
    for (stamp, commit, label), values in runs.items():
        print("  ".join([stamp, commit, label or "-"] + [values.get(c, "-") for c in columns]))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "history":
        history(sys.argv[2:])
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="", help="name for this run, e.g. 'pooled threads'")
    parser.add_argument("--secs", type=float, default=3.0, help="duration of timed scenarios")
    parser.add_argument("--servers", default="roc,threads,tokio")
    args = parser.parse_args()
    servers = args.servers.split(",")

    print("Building...", flush=True)
    build()
    commit = git_commit()
    results = {s: {} for s in servers}
    port = 19000
    for server in servers:
        for scenario in SCENARIOS:
            port += 1
            print(f"  {server:8} {scenario[0]:12}", end="", flush=True)
            metrics = run_scenario(server, scenario, port, args.secs)
            # Leftover TIME_WAIT sockets use up ephemeral ports and would make
            # later scenarios fail for reasons unrelated to the server.
            leftover = time_wait_count()
            if leftover > 1000:
                metrics["warning"] = f"{leftover} sockets in TIME_WAIT"
            results[server][scenario[0]] = metrics
            print(" ", json.dumps(metrics), flush=True)
    record(results, args.label, commit)
    print(f"\nCommit {commit}, {args.secs:g}s per timed scenario. Recorded in {RESULTS.relative_to(ROOT)}.\n")
    summarize(results, servers)


if __name__ == "__main__":
    main()
