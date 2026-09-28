app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Task
import pf.Tcp

# Demonstrates: a task per direction, kept together with `Task.scope!`
#
# Usage: tcp_proxy LISTEN_ADDRESS UPSTREAM_ADDRESS

main! : List(Str) => Try({}, _)
main! = |args| {
	(listen_address, upstream_address) =
		match args {
			[_, listen, upstream] => (listen, upstream)
			_ => return Err(Exit(2))
		}

	# Proxied sessions (SSH, say) can be quiet for long stretches, so allow an
	# hour of silence (the default drops a client after 60 seconds).
	listener = Tcp.listen_with!(listen_address, Tcp.listen_config.with_idle_timeout(Millis(3600000)))?
	Stdout.line!("Proxying ${listen_address} -> ${upstream_address}")?

	while True {
		client = listener.accept!()?
		# At the task limit this fails and drops the connection; the proxy keeps going.
		_ = Task.spawn!(|| {
			upstream = Tcp.connect!(upstream_address)?
			# One task per direction, in a scope, so neither outlives the
			# connection: if this direction fails, the other is cancelled.
			Task.scope!(|scope| {
				_ = scope.spawn!(|| pipe!(client, upstream))?
				pipe!(upstream, client)
			})
		})
	}

	Ok({})
}

## Copy bytes from `from` to `to`. When `from` ends, pass that on (`to` stops
## writing) and leave the other direction running: a client may send its
## request, close its side, and still read the reply. On an error, close both,
## which also ends the other direction's wait.
pipe! : Tcp.Stream, Tcp.Stream => Try({}, _)
pipe! = |from, to| {
	result = copy!(from, to)
	match result {
		Ok({}) => to.shutdown!(Write)
		Err(_) => {
			from.close!()
			to.close!()
			result
		}
	}
}

copy! = |from, to| {
	while True {
		bytes = from.read!(16384)?
		if List.is_empty(bytes) {
			break
		}
		to.write!(bytes)?
	}
	Ok({})
}
