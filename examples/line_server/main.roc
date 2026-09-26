app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Framing
import pf.Stdout
import pf.Task
import pf.Tcp

# Demonstrates: Framing.reader, a line-based request/response protocol
#
# Usage: line_server [ADDRESS]
#
# Try it with `nc 127.0.0.1 8080` and type:
#   ECHO hello        -> hello
#   ADD 2 40          -> 42
#   QUIT              -> BYE (and the server hangs up)

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
		_ = Task.spawn!(|| serve!(stream))
	}

	Ok({})
}

serve! = |stream|
	Framing.each_line!(stream, |line|
		match respond(line) {
			Reply(text) => stream.write_str!("${text}\n").map_ok(|_| Continue)
			Hangup(text) => stream.write_str!("${text}\n").map_ok(|_| Stop)
		})

respond : Str -> [Reply(Str), Hangup(Str)]
respond = |line|
	match Str.split_first(line, " ") {
		Ok({ before: "ECHO", after }) => Reply(after)
		Ok({ before: "ADD", after }) =>
			match Str.split_on(after, " ").map(I64.from_str) {
				[Ok(a), Ok(b)] => Reply((a + b).to_str())
				_ => Reply("ERR usage: ADD <int> <int>")
			}
		_ if line == "QUIT" => Hangup("BYE")
		_ => Reply("ERR unknown command")
	}
