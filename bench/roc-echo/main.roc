app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Task
import pf.Tcp

# Benchmark server. Same behavior as bench/src/bin/echo-*.rs: one task per
# connection, 4 KiB reads, and a connection error silently ends that
# connection (the example server logs it instead).

main! : List(Str) => Try({}, _)
main! = |args| {
	address =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "127.0.0.1:8080"
		}
	listener = Tcp.listen!(address)?
	while True {
		stream = listener.accept!()?
		_ = Task.spawn!(|| {
			_ = echo!(stream)
			Ok({})
		})
	}
	Ok({})
}

# read_into! reuses one buffer for every read (the Rust baselines do too).
echo! = |stream| {
	var $buf = List.with_capacity(4096)
	while True {
		$buf = stream.read_into!($buf, 4096)?
		if List.is_empty($buf) {
			break
		}
		stream.write!($buf)?
	}
	Ok({})
}
