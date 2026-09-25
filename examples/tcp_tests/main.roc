app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Task
import pf.Tcp

# Tests the Tcp module end to end. Each test starts its own server task on a
# port the OS picks, so tests never collide with each other or other programs.

main! : List(Str) => Try({}, _)
main! = |_args| {
	results = [
		check!("round trip", round_trip!),
		check!("half-close", half_close!),
		check!("read timeout", read_timeout!),
		check!("connection refused", connection_refused!),
		check!("addresses", addresses!),
	]
	failed = List.len(List.keep_if(results, |passed| !passed))
	if failed == 0 {
		Stdout.line!("All ${List.len(results).to_str()} tests passed")?
		Ok({})
	} else {
		Stdout.line!("${failed.to_str()} of ${List.len(results).to_str()} tests failed")?
		Err(Exit(1))
	}
}

check! = |name, test!|
	match test!() {
		Ok({}) => {
			_ = Stdout.line!("ok    ${name}")
			True
		}
		Err(err) => {
			_ = Stdout.line!("FAIL  ${name}: ${Str.inspect(err)}")
			False
		}
	}

expect_eq = |actual, expected|
	if actual == expected {
		Ok({})
	} else {
		Err(Mismatch({ expected, actual }))
	}

## Read until the peer closes its side.
read_to_end! = |stream| {
	var $bytes = []
	while True {
		chunk = stream.read!(4096)?
		if List.is_empty(chunk) {
			break
		}
		$bytes = List.concat($bytes, chunk)
	}
	Ok(Str.from_utf8_lossy($bytes))
}

## Listen on a free port and return the listener with its address.
listen_anywhere! = || {
	listener = Tcp.listen!("127.0.0.1:0")?
	address = listener.local_addr!()?
	Ok((listener, address))
}

# The server echoes one message and ends its task, which drops (and so
# closes) its stream; the client reads until that close.
round_trip! = || {
	(listener, address) = listen_anywhere!()?
	Task.spawn!(|| {
		stream = listener.accept!()?
		bytes = stream.read!(1024)?
		stream.write!(bytes)
	})?

	client = Tcp.connect!(address)?
	client.write_str!("hello")?
	expect_eq(read_to_end!(client)?, "hello")
}

# The client says it is done sending; the server reads to the end, replies,
# and the client can still read that reply.
half_close! = || {
	(listener, address) = listen_anywhere!()?
	Task.spawn!(|| {
		stream = listener.accept!()?
		request = read_to_end!(stream)?
		stream.write_str!("got ${Str.count_utf8_bytes(request).to_str()} bytes")
	})?

	client = Tcp.connect!(address)?
	client.write_str!("ping")?
	client.shutdown!(Write)?
	expect_eq(read_to_end!(client)?, "got 4 bytes")
}

# The server accepts but never writes, so the client's read must time out.
read_timeout! = || {
	(listener, address) = listen_anywhere!()?
	Task.spawn!(|| {
		stream = listener.accept!()?
		_ = read_to_end!(stream)?
		Ok({})
	})?

	client = Tcp.connect!(address)?
	client.set_read_timeout!(Millis(100))?
	match client.read!(16) {
		Err(TcpErr(TimedOut)) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# Nothing refers to the listener after `listen_anywhere!` returns, so it is
# closed and connecting to its old address is refused.
connection_refused! = || {
	(_, address) = listen_anywhere!()?
	match Tcp.connect!(address) {
		Err(TcpErr(ConnectionRefused)) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# The server reports the address it sees for the client, which must match the
# client's own view of its local address.
addresses! = || {
	(listener, address) = listen_anywhere!()?
	Task.spawn!(|| {
		stream = listener.accept!()?
		stream.write_str!(stream.peer_addr!()?)
	})?

	client = Tcp.connect!(address)?
	client.set_nodelay!(True)?
	expect_eq(client.peer_addr!()?, address)?
	expect_eq(read_to_end!(client)?, client.local_addr!()?)
}
