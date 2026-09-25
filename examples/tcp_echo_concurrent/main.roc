app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Task
import pf.Tcp

# Demonstrates: Task.spawn!, serving many clients at once
#
# Usage: tcp_echo_concurrent [ADDRESS]

main! : List(Str) => Try({}, _)
main! = |args| {
	address =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "127.0.0.1:8080"
		}

	listener = Tcp.listen!(address)?
	Stdout.line!("Listening on ${address}")?

	while True {
		stream = listener.accept!()?
		Task.spawn!(|| echo!(stream))?
	}

	Ok({})
}

echo! : Tcp.Stream => Try({}, _)
echo! = |stream| {
	while True {
		bytes = stream.read!(4096)?
		if List.is_empty(bytes) {
			break
		}
		stream.write!(bytes)?
	}
	stream.close!()
	Ok({})
}
