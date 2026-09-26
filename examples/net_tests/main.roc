app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Bytes
import pf.Dns
import pf.Framing
import pf.Random
import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Time
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
		check!("framing: lines split across writes", framing_lines!),
		check!("framing: length-prefixed frames", framing_frames!),
		check!("framing: line longer than the limit", framing_too_long!),
		check!("framing: stream ends mid-frame", framing_truncated!),
		check!("framing: each_line! stops on Stop", framing_each_line!),
		check!("framing: fold_lines! carries state", framing_fold_lines!),
		check!("framing: each_frame! until end of stream", framing_each_frame!),
		check!("bytes: known encodings", bytes_encodings!),
		check!("bytes: round trips and TooShort", bytes_round_trips!),
		check!("time: sleep and elapsed", time_sleep!),
		check!("time: durations", time_durations!),
		check!("dns: resolve", dns_resolve!),
		check!("bytes: reading at offsets", bytes_offsets!),
		check!("random: bytes differ", random_bytes!),
		check!("random: between! stays in range and covers it", random_between!),
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

## Values are shown as text in the error, so one test can compare values of
## different types.
expect_eq = |actual, expected|
	if actual == expected {
		Ok({})
	} else {
		Err(Mismatch({ expected: Str.inspect(expected), actual: Str.inspect(actual) }))
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

## Accept one connection and run `send!` on it, then hang up.
serve_once! = |listener, send!|
	Task.spawn!(|| {
		stream = listener.accept!()?
		stream.set_nodelay!(True)?
		send!(stream)
	})

framing_lines! = || {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| {
		stream.write_str!("first li")?
		stream.write_str!("ne\r\nsecond\nthi")?
		stream.write_str!("rd\n")
	})?

	reader = Framing.reader(Tcp.connect!(address)?)
	(a, r1) = reader.read_line!()?
	(b, r2) = r1.read_line!()?
	(c, r3) = r2.read_line!()?
	expect_eq([a, b, c], ["first line", "second", "third"])?
	match r3.read_line!() {
		Err(EndOfStream) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

framing_frames! = || {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| {
		Framing.write_frame!(stream, Str.to_utf8("hello"))?
		Framing.write_frame!(stream, [])?
		Framing.write_frame!(stream, List.repeat(7, 100000))
	})?

	reader = Framing.reader(Tcp.connect!(address)?)
	(hello, r1) = reader.read_frame!()?
	(empty, r2) = r1.read_frame!()?
	(big, _) = r2.read_frame!()?
	expect_eq((Str.from_utf8_lossy(hello), List.len(empty), List.len(big)), ("hello", 0, 100000))
}

framing_too_long! = || {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| stream.write!(List.repeat(65, 5000)))?

	reader = Framing.reader_with_max(Tcp.connect!(address)?, 1000)
	match reader.read_line!() {
		Err(TooLong) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

framing_truncated! = || {
	(listener, address) = listen_anywhere!()?
	# Promise 10 bytes, send 3, hang up.
	serve_once!(listener, |stream| stream.write!([0, 0, 0, 10, 1, 2, 3]))?

	reader = Framing.reader(Tcp.connect!(address)?)
	match reader.read_frame!() {
		Err(UnexpectedEof) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# The server echoes lines wrapped in <> until a line says "stop".
framing_each_line! = || {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream|
		Framing.each_line!(stream, |line|
			if line == "stop" {
				Ok(Stop)
			} else {
				stream.write_str!("<${line}>").map_ok(|_| Continue)
			}))?

	client = Tcp.connect!(address)?
	expect_eq(exchange!(client, "a\nb\nstop\nc\n")?, "<a><b>")
}

# The server counts lines until the client stops sending, then reports.
framing_fold_lines! = || {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| {
		count = Framing.fold_lines!(stream, 0.U64, |n, _line| Ok(Continue(n + 1)))?
		stream.write_str!("${count.to_str()} lines")
	})?

	client = Tcp.connect!(address)?
	expect_eq(exchange!(client, "one\ntwo\nthree\n")?, "3 lines")
}

# The server echoes each frame back with its length, until the client hangs up.
framing_each_frame! = || {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream|
		Framing.each_frame!(stream, |frame|
			Framing.write_frame!(stream, Str.to_utf8("${List.len(frame).to_str()}:${Str.from_utf8_lossy(frame)}"))
				.map_ok(|_| Continue)))?

	client = Tcp.connect!(address)?
	Framing.write_frame!(client, Str.to_utf8("ab"))?
	Framing.write_frame!(client, Str.to_utf8("cde"))?
	client.shutdown!(Write)?
	replies = Framing.fold_frames!(client, [], |so_far, frame| Ok(Continue(List.append(so_far, Str.from_utf8_lossy(frame)))))?
	expect_eq(replies, ["2:ab", "3:cde"])
}

bytes_encodings! = || {
	expect_eq(Bytes.u16_be(258), [1, 2])?
	expect_eq(Bytes.u32_be(16909060), [1, 2, 3, 4])?
	expect_eq(Bytes.u64_be(72623859790382856), [1, 2, 3, 4, 5, 6, 7, 8])?
	expect_eq(Bytes.u16_le(258), [2, 1])?
	expect_eq(Bytes.u32_le(16909060), [4, 3, 2, 1])?
	expect_eq(Bytes.u64_le(72623859790382856), [8, 7, 6, 5, 4, 3, 2, 1])
}

bytes_round_trips! = || {
	tail = [9, 9]
	expect_eq(Bytes.take_u16_be(List.concat(Bytes.u16_be(65535), tail)), Ok((65535, tail)))?
	expect_eq(Bytes.take_u32_be(List.concat(Bytes.u32_be(4294967295), tail)), Ok((4294967295, tail)))?
	expect_eq(Bytes.take_u64_be(List.concat(Bytes.u64_be(18446744073709551615), tail)), Ok((18446744073709551615, tail)))?
	expect_eq(Bytes.take_u16_le(List.concat(Bytes.u16_le(4660), tail)), Ok((4660, tail)))?
	expect_eq(Bytes.take_u32_le(List.concat(Bytes.u32_le(305419896), tail)), Ok((305419896, tail)))?
	expect_eq(Bytes.take_u64_le(List.concat(Bytes.u64_le(1311768467463790320), tail)), Ok((1311768467463790320, tail)))?
	expect_eq(Bytes.take_u8([7, 8]), Ok((7, [8])))?
	expect_eq(Bytes.take([1, 2, 3], 2), Ok(([1, 2], [3])))?
	expect_eq(Bytes.take_u32_be([1, 2, 3]), Err(TooShort))?
	expect_eq(Bytes.take([1], 2), Err(TooShort))
}

time_sleep! = || {
	start = Time.now!()
	Time.sleep!(Time.millis(50))
	took = start.elapsed!().to_millis()
	if took >= 50 and took < 500 {
		Ok({})
	} else {
		Err(Unexpected("slept 50 ms but measured ${took.to_str()} ms"))
	}
}

time_durations! = || {
	expect_eq(Time.seconds(2).to_millis(), 2000)?
	expect_eq(Time.millis(3).to_micros(), 3000)?
	expect_eq(Time.micros(5).to_nanos(), 5000)?
	expect_eq(Time.millis(5).minus(Time.millis(2)).to_millis(), 3)?
	# Subtracting a longer duration gives zero rather than wrapping around.
	expect_eq(Time.millis(2).minus(Time.millis(5)).to_nanos(), 0)?
	expect_eq(Time.millis(1).plus(Time.micros(500)).to_micros(), 1500)
}

dns_resolve! = || {
	expect_eq(Dns.resolve!("127.0.0.1")?, ["127.0.0.1"])?
	localhost = Dns.resolve!("localhost")?
	if !(List.contains(localhost, "127.0.0.1") or List.contains(localhost, "::1")) {
		return Err(Unexpected("localhost resolved to ${Str.inspect(localhost)}"))
	}
	match Dns.resolve!("no-such-host.invalid") {
		Err(DnsErr(_)) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

bytes_offsets! = || {
	data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
	expect_eq(Bytes.u8_at(data, 9), Ok(10))?
	expect_eq(Bytes.u16_be_at(data, 1), Ok(515))?
	expect_eq(Bytes.u16_le_at(data, 1), Ok(770))?
	expect_eq(Bytes.u32_be_at(data, 6), Ok(117967114))?
	expect_eq(Bytes.u64_be_at(data, 2), Ok(217304205466536202))?
	expect_eq(Bytes.u64_le_at(data, 2), Ok(723118041428460547))?
	expect_eq(Bytes.bytes_at(data, 3, 2), Ok([4, 5]))?
	# Reading nothing at the very end is fine; reading past it is not.
	expect_eq(Bytes.bytes_at(data, 10, 0), Ok([]))?
	expect_eq(Bytes.u8_at(data, 10), Err(TooShort))?
	expect_eq(Bytes.u32_be_at(data, 7), Err(TooShort))?
	expect_eq(Bytes.bytes_at(data, 8, 5), Err(TooShort))
}

random_bytes! = || {
	a = Random.bytes!(16)
	b = Random.bytes!(16)
	expect_eq(List.len(a), 16)?
	# Equal by chance with probability 2^-128.
	if a == b Err(Unexpected("two random draws were equal")) else Ok({})
}

random_between! = || {
	var $seen = [False, False, False, False, False, False]
	for _ in U64.until(0, 2000) {
		roll = Random.between!(1, 6)
		if roll < 1 or roll > 6 {
			return Err(Unexpected("between!(1, 6) returned ${roll.to_str()}"))
		}
		$seen = List.set($seen, roll - 1, True)?
	}
	# Missing a face in 2000 rolls happens with probability about 10^-157.
	expect_eq($seen, [True, True, True, True, True, True])?
	expect_eq(Random.between!(5, 5), 5)?
	expect_eq(Random.between!(9, 3), 9)?
	# The full range must not loop forever.
	_ = Random.between!(0, U64.highest)
	Ok({})
}
