app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stderr
import pf.Stdout
import pf.Tcp

# Demonstrates: Tcp.listen!, accepting connections, echoing bytes back
#
# Usage: tcp_echo_server [ADDRESS] [MAX_CONNECTIONS]
# Serves one client at a time. With MAX_CONNECTIONS, exits after that many.

main! : List(Str) => Try({}, _)
main! = |args| {
	address =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "127.0.0.1:8080"
		}
	max_connections =
		match List.get(args, 2) {
			Ok(arg) =>
				match U64.from_str(arg) {
					Ok(n) => n
					Err(_) => 0
				}
			Err(_) => 0
		}

	listener = Tcp.listen!(address)?
	Stdout.line!("Listening on ${address}")?

	var $served = 0
	while max_connections == 0 or $served < max_connections {
		stream = listener.accept!()?
		match echo!(stream) {
			Ok({}) => {}
			Err(TcpErr(err)) => {
				_ = Stderr.line!("connection error: ${Str.inspect(err)}")
			}
		}
		$served = $served + 1
	}

	Ok({})
}

echo! : Tcp.Stream => Try({}, _)
echo! = |stream| {
	var $open = True
	while $open {
		bytes = stream.read!(4096)?
		if List.is_empty(bytes) {
			$open = False
		} else {
			stream.write!(bytes)?
		}
	}
	Ok({})
}
