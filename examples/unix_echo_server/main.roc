app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Task
import pf.Unix

# Demonstrates: Unix.listen!, serving local clients over a socket file
#
# Usage: unix_echo_server [PATH]
#
# The code is the TCP echo server's with `Tcp` replaced by `Unix`: the stream
# methods are the same.

main! : List(Str) => Try({}, _)
main! = |args| {
	path =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "/tmp/roc-net-echo.sock"
		}

	listener = Unix.listen!(path)?
	Stdout.line!("Listening on ${path}")?

	while True {
		stream = listener.accept!()?
		# At the task limit this fails and drops the connection; the server keeps going.
		_ = Task.spawn!(|| echo!(stream))
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
