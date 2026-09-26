#!/usr/bin/env python3
"""Install the Linux musl runtime files (crt1.o, libc.a, ...) needed to build
Linux binaries, from the release pinned in runtime/link-inputs.lock.json.

This is `ci/runtime.py fetch` minus its producer-fingerprint check, which
compares local copies of the template's release tooling (including GitHub
workflows this repo no longer has) with the ones that produced the release.
The download is still verified against the SHA-256 and size committed in the
lock, which pins it to the exact reviewed archive.

    scripts/fetch_linux_runtime.py [arm64musl] [x64musl]
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("runtime", ROOT / "ci/runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def fetch(target):
    lock = runtime.read_json(runtime.LOCK)
    record = lock["targets"][target]
    cache = Path.home() / ".cache/roc-net/link-inputs"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / record["sha256"]

    def matches():
        return (archive.is_file() and archive.stat().st_size == record["size"]
                and runtime.digest(archive.read_bytes()) == record["sha256"])

    if not matches():
        url = f"https://github.com/{lock['repository']}/releases/download/{lock['release']}/{record['asset']}"
        print(f"downloading {url}")
        archive.unlink(missing_ok=True)
        # curl uses the system's certificate store (the python.org build of
        # Python on macOS has none until "Install Certificates" is run).
        subprocess.run(["curl", "-fsSL", "--proto", "=https", "-o", str(archive), url], check=True)
        if not matches():
            archive.unlink(missing_ok=True)
            sys.exit(f"{target}: download doesn't match the SHA-256 and size in {runtime.LOCK}")
    runtime.install_target_archive(archive, target)
    print(f"{target}: installed into platform/targets/{target}")


for target in sys.argv[1:] or ["arm64musl"]:
    fetch(target)
