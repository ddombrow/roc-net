app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Unix

# Demonstrates: Unix.connect!, a request/response exchange over a socket file
#
# Usage: unix_client [PATH] [MESSAGE]

main! : List(Str) => Try({}, _)
main! = |args| {
	path =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "/tmp/roc-net-echo.sock"
		}
	message =
		match List.get(args, 2) {
			Ok(arg) => arg
			Err(_) => "Hello from Roc!"
		}

	stream =
		match Unix.connect!(path) {
			Ok(s) => s
			Err(UnixErr(NotFound)) | Err(UnixErr(ConnectionRefused)) => {
				Stdout.line!("No server at ${path}. Start one first, e.g. `just run unix_echo_server ${path}`.")?
				return Err(Exit(1))
			}
			Err(err) => return Err(err)
		}
	stream.write_str!(message)?
	reply = stream.read!(4096)?

	Stdout.line!("Received: ${Str.from_utf8_lossy(reply)}")
}
