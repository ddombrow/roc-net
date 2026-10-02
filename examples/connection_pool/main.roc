app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Channel
import pf.Framing
import pf.Stdout
import pf.Task
import pf.Tcp

# Demonstrates: a pool of connections to a backend, shared by many tasks.
#
# Usage: connection_pool BACKEND_ADDRESS
#
# Twenty tasks each make five requests to a line server (such as
# `line_server`) through a pool of at most four connections, then it prints
# how many connections served the hundred requests:
#
#   line_server 127.0.0.1:8080          # then, elsewhere:
#   connection_pool 127.0.0.1:8080
#
# The pool is a channel holding one slot per connection allowed, each either
# an open connection or empty. Borrowing waits for a slot, so at most that
# many requests run at once; an empty slot is filled by connecting, so
# connections open only as they're needed; a connection that fails goes
# back as an empty slot, to be replaced. This is example code, not part of
# the platform: what to pool, and when a connection is healthy, depend on
# the protocol.

main! : List(Str) => Try({}, _)
main! = |args| {
	address =
		match args {
			[_, a] => a
			_ => {
				Stdout.line!("Usage: connection_pool BACKEND_ADDRESS")?
				return Err(Exit(2))
			}
		}
	pool = new_pool!(address, 4)?
	used =
		Task.scope!(|scope| {
			var $handles = []
			var $i = 0
			while $i < 20 {
				task = $i
				$i = $i + 1
				handle = scope.spawn!(|| {
					var $ports = []
					var $j = 0
					while $j < 5 {
						port = with_connection!(pool, |stream| request!(stream, "ECHO task ${task.to_str()} request ${$j.to_str()}"))?
						$ports = List.append($ports, port)
						$j = $j + 1
					}
					Ok($ports)
				})?
				$handles = List.append($handles, handle)
			}
			var $all = []
			for handle in $handles {
				$all = List.concat($all, handle.join!()?)
			}
			Ok($all)
		})?
	connections = List.len(distinct(used))
	Stdout.line!("${List.len(used).to_str()} requests over ${connections.to_str()} connections")
}

## A pool of at most `size` connections to `address`, none open yet.
new_pool! = |address, size| {
	(give_back, take) = Channel.new!(size)?
	var $n = 0
	while $n < size {
		give_back.send!(Empty)?
		$n = $n + 1
	}
	Ok({ address, give_back, take })
}

## Run `use!` on a connection from `pool`, then put it back.
with_connection! = |pool, use!| {
	slot = pool.take.receive!()?
	(result, back) =
		match slot {
			Open(stream) =>
				match use!(stream) {
					Ok(value) => (Ok(value), Open(stream))
					# A connection the server closed while it sat in the pool
					# fails on its first use: try once more on a fresh one. Only
					# for requests that are safe to send twice.
					Err(_) => fresh!(pool, use!)
				}
			Empty => fresh!(pool, use!)
		}
	pool.give_back.send!(back)?
	result
}

## `use!` on a new connection, and the slot to put back.
fresh! = |pool, use!|
	match Tcp.connect!(pool.address) {
		Err(err) => (Err(err), Empty)
		Ok(stream) =>
			match use!(stream) {
				Ok(value) => (Ok(value), Open(stream))
				Err(err) => (Err(err), Empty)
			}
	}

## One request and its reply; returns the connection's local address, to
## tell connections apart.
request! = |stream, line| {
	stream.set_read_timeout!(Millis(5000))?
	stream.write_str!("${line}\n")?
	(_, _) = Framing.reader(stream).read_line!()?
	stream.local_addr!()
}

distinct = |items|
	List.fold(items, [], |seen, item| if List.contains(seen, item) seen else List.append(seen, item))
