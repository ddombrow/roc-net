app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Tcp

# Demonstrates: Tcp.connect!, writing a request, reading the reply
#
# Usage: tcp_client [ADDRESS] [MESSAGE]

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str), TcpErr(Str)])
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

	stream = Tcp.connect!(address)?
	stream.write_str!(message)?
	reply = stream.read!(4096)?
	stream.close!()

	Stdout.line!("Received: ${Str.from_utf8_lossy(reply)}")
}
