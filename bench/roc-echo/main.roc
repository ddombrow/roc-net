app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

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

echo! = |stream| {
	while True {
		bytes = stream.read!(4096)?
		if List.is_empty(bytes) {
			break
		}
		stream.write!(bytes)?
	}
	Ok({})
}
