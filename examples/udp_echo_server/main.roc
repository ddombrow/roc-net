app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Udp

# Demonstrates: Udp.bind!, receiving datagrams and replying to their sender
#
# Usage: udp_echo_server [ADDRESS]
#
# One socket serves every client: each datagram carries its sender's address,
# so there is no accept loop and no task per client.

main! : List(Str) => Try({}, _)
main! = |args| {
	address =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "127.0.0.1:8080"
		}

	socket = Udp.bind!(address)?
	Stdout.line!("Listening for datagrams on ${address}")?

	while True {
		received = socket.recv_from!(65536)?
		socket.send_to!(received.bytes, received.from)?
	}

	Ok({})
}
