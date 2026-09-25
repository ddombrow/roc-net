app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Tcp

# Demonstrates: Tcp.connect!, handling a specific error, writing a request, reading the reply
#
# Usage: tcp_client [ADDRESS] [MESSAGE]

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

	stream =
		match Tcp.connect!(address) {
			Ok(s) => s
			Err(TcpErr(ConnectionRefused)) => {
				Stdout.line!("Nothing is listening on ${address}. Start a server first, e.g. `just run tcp_echo_concurrent ${address}`.")?
				return Err(Exit(1))
			}
			Err(err) => return Err(err)
		}
	stream.write_str!(message)?
	reply = stream.read!(4096)?

	Stdout.line!("Received: ${Str.from_utf8_lossy(reply)}")
}
