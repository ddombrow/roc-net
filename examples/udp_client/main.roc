app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Udp

# Demonstrates: sending a datagram and waiting for the reply with a timeout
#
# Usage: udp_client [ADDRESS] [MESSAGE]

main! : List(Str) => Try({}, _)
main! = |args| {
	address =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "127.0.0.1:8080"
		}
	message =
		match List.get(args, 2) {
			Ok(arg) => arg
			Err(_) => "Hello from Roc!"
		}

	# Port 0: let the OS pick a free local port for our replies.
	socket = Udp.bind!("0.0.0.0:0")?
	socket.connect!(address)?
	# A lost datagram is never delivered, so don't wait forever for a reply.
	socket.set_read_timeout!(Millis(2000))?
	socket.send!(Str.to_utf8(message))?

	match socket.recv!(65536) {
		Ok(reply) => Stdout.line!("Received: ${Str.from_utf8_lossy(reply)}")
		Err(UdpErr(TimedOut)) => {
			Stdout.line!("No reply from ${address} within 2 seconds.")?
			Err(Exit(1))
		}
		Err(UdpErr(ConnectionRefused)) => {
			Stdout.line!("Nothing is listening on ${address}. Start a server first, e.g. `just run udp_echo_server ${address}`.")?
			Err(Exit(1))
		}
		Err(err) => Err(err)
	}
}
