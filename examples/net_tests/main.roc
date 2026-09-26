app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Udp
import pf.Unix

# Tests the Tcp, Unix, and Udp modules end to end. Each test starts its own
# server task on a port the OS picks (or its own socket path), so tests never
# collide with each other or with other programs.

main! : List(Str) => Try({}, _)
main! = |_args| {
	results = [
		check!("round trip", round_trip!),
		check!("half-close", half_close!),
		check!("read timeout", read_timeout!),
		check!("connection refused", connection_refused!),
		check!("addresses", addresses!),
		check!("unix round trip", unix_round_trip!),
		check!("unix half-close, same helper as TCP", unix_half_close!),
		check!("unix listener removes its socket file", unix_cleanup!),
		check!("udp round trip", udp_round_trip!),
		check!("udp connected", udp_connected!),
		check!("udp read timeout", udp_read_timeout!),
		check!("udp truncates long datagrams", udp_truncate!),
		check!("udp connected to closed port", udp_refused!),
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

## Send `message`, say we're done sending, and read the whole reply.
##
## Like `read_to_end!`, this only calls stream methods, so it works for both
## `Tcp.Stream` and `Unix.Stream`.
exchange! = |stream, message| {
	stream.write_str!(message)?
	stream.shutdown!(Write)?
	read_to_end!(stream)
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
	expect_eq(exchange!(client, "ping")?, "got 4 bytes")
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

## A server that reads a whole request and replies with its length. Works for
## TCP and Unix listeners alike.
serve_length! = |listener| {
	Task.spawn!(|| {
		stream = listener.accept!()?
		request = read_to_end!(stream)?
		stream.write_str!("got ${Str.count_utf8_bytes(request).to_str()} bytes")
	})
}

unix_round_trip! = || {
	path = "/tmp/roc-net-tests-round-trip.sock"
	listener = Unix.listen!(path)?
	expect_eq(listener.local_addr!()?, path)?
	Task.spawn!(|| {
		stream = listener.accept!()?
		bytes = stream.read!(1024)?
		stream.write!(bytes)
	})?

	client = Unix.connect!(path)?
	client.write_str!("hello unix")?
	expect_eq(read_to_end!(client)?, "hello unix")
}

# The same helpers drive a Unix stream as drove TCP in `half_close!`.
unix_half_close! = || {
	listener = Unix.listen!("/tmp/roc-net-tests-half-close.sock")?
	serve_length!(listener)?

	client = Unix.connect!("/tmp/roc-net-tests-half-close.sock")?
	expect_eq(exchange!(client, "ping pong")?, "got 9 bytes")
}

# Nothing refers to the listener after `listen_on!` returns, so it is closed
# and its socket file deleted: connecting finds no file at all.
unix_cleanup! = || {
	path = listen_on!("/tmp/roc-net-tests-cleanup.sock")?
	match Unix.connect!(path) {
		Err(UnixErr(NotFound)) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

listen_on! = |path| {
	listener = Unix.listen!(path)?
	listener.local_addr!()
}

## Bind a UDP socket on a free port and return it with its address.
udp_anywhere! = || {
	socket = Udp.bind!("127.0.0.1:0")?
	address = socket.local_addr!()?
	Ok((socket, address))
}

# The server echoes one datagram back to whoever sent it.
udp_echo_once! = |server| {
	Task.spawn!(|| {
		received = server.recv_from!(1024)?
		server.send_to!(received.bytes, received.from)
	})
}

udp_round_trip! = || {
	(server, server_address) = udp_anywhere!()?
	udp_echo_once!(server)?

	(client, _) = udp_anywhere!()?
	client.set_read_timeout!(Millis(2000))?
	client.send_to!(Str.to_utf8("ping"), server_address)?
	reply = client.recv_from!(1024)?
	expect_eq(Str.from_utf8_lossy(reply.bytes), "ping")?
	expect_eq(reply.from, server_address)
}

udp_connected! = || {
	(server, server_address) = udp_anywhere!()?
	udp_echo_once!(server)?

	(client, _) = udp_anywhere!()?
	client.set_read_timeout!(Millis(2000))?
	client.connect!(server_address)?
	expect_eq(client.peer_addr!()?, server_address)?
	client.send!(Str.to_utf8("hello"))?
	expect_eq(Str.from_utf8_lossy(client.recv!(1024)?), "hello")
}

udp_read_timeout! = || {
	(socket, _) = udp_anywhere!()?
	socket.set_read_timeout!(Millis(100))?
	match socket.recv_from!(1024) {
		Err(UdpErr(TimedOut)) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

udp_truncate! = || {
	(receiver, address) = udp_anywhere!()?
	(sender, _) = udp_anywhere!()?
	receiver.set_read_timeout!(Millis(2000))?
	sender.send_to!(Str.to_utf8("0123456789"), address)?
	expect_eq(Str.from_utf8_lossy(receiver.recv_from!(4)?.bytes), "0123")
}

# A connected UDP socket learns from the OS that nothing is listening.
udp_refused! = || {
	(_, closed_address) = udp_anywhere!()?
	(client, _) = udp_anywhere!()?
	client.set_read_timeout!(Millis(2000))?
	client.connect!(closed_address)?
	client.send!(Str.to_utf8("anyone?"))?
	match client.recv!(1024) {
		Err(UdpErr(ConnectionRefused)) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}
