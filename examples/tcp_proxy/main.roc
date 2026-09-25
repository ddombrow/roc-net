app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Task
import pf.Tcp

# Demonstrates: two tasks per connection, copying bytes in both directions
#
# Usage: tcp_proxy LISTEN_ADDRESS UPSTREAM_ADDRESS

main! : List(Str) => Try({}, _)
main! = |args| {
	(listen_address, upstream_address) =
		match args {
			[_, listen, upstream] => (listen, upstream)
			_ => return Err(Exit(2))
		}

	listener = Tcp.listen!(listen_address)?
	Stdout.line!("Proxying ${listen_address} -> ${upstream_address}")?

	while True {
		client = listener.accept!()?
		Task.spawn!(|| {
			upstream = Tcp.connect!(upstream_address)?
			Task.spawn!(|| pipe!(client, upstream))?
			pipe!(upstream, client)
		})?
	}

	Ok({})
}

## Copy bytes from `from` to `to` until either side closes, then close both,
## which also stops the pipe running in the other direction.
pipe! : Tcp.Stream, Tcp.Stream => Try({}, _)
pipe! = |from, to| {
	while True {
		bytes = from.read!(16384)?
		if List.is_empty(bytes) {
			break
		}
		to.write!(bytes)?
	}
	from.close!()
	to.close!()
	Ok({})
}
