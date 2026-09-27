app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Bytes
import pf.Channel
import pf.Dns
import pf.Framing
import pf.Random
import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Time
import pf.Tls
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
		check!("unix connect gives up when the listener's queue stays full", unix_backlog_full!),
		check!("udp round trip", udp_round_trip!),
		check!("udp connected", udp_connected!),
		check!("udp read timeout", udp_read_timeout!),
		check!("udp truncates long datagrams", udp_truncate!),
		check!("udp connected to closed port", udp_refused!),
		check!("framing: lines split across writes", framing_lines!),
		check!("framing: length-prefixed frames", framing_frames!),
		check!("framing: line longer than the limit", framing_too_long!),
		check!("framing: stream ends mid-frame", framing_truncated!),
		check!("framing: over-limit line in a single read is rejected", framing_limit_single_read!),
		check!("framing: line of exactly the limit is accepted, however it arrives", framing_limit_boundary!),
		check!("framing: read_exactly! past the limit is rejected", framing_limit_exactly!),
		check!("framing: frames with a limit under the header size", framing_limit_small_frames!),
		check!("framing: each_line! stops on Stop", framing_each_line!),
		check!("framing: fold_lines! carries state", framing_fold_lines!),
		check!("framing: each_frame! until end of stream", framing_each_frame!),
		check!("bytes: known encodings", bytes_encodings!),
		check!("bytes: round trips and TooShort", bytes_round_trips!),
		check!("time: sleep and elapsed", time_sleep!),
		check!("time: durations", time_durations!),
		check!("time: enormous timeouts don't crash", huge_timeouts!),
		check!("dns: resolve", dns_resolve!),
		check!("bytes: reading at offsets", bytes_offsets!),
		check!("random: bytes differ", random_bytes!),
		check!("random: between! stays in range and covers it", random_between!),
		check!("channel: values arrive in order", channel_order!),
		check!("channel: closes when the producer task ends", channel_producer_ends!),
		check!("channel: many producers, closes after the last", channel_many_producers!),
		check!("channel: capacity 1 applies backpressure, loses nothing", channel_backpressure!),
		check!("channel: try_send!, try_receive!, receive_timeout!", channel_non_blocking!),
		check!("channel: close! delivers what's queued", channel_close!),
		check!("channel: send fails once the receiver is gone", channel_receiver_gone!),
		check!("channel: reply channels sent through a channel", channel_reply!),
		check!("channel: undelivered values are freed", channel_frees_values!),
		check!("tls: round trip, same helpers as TCP", tls_round_trip!),
		check!("tls: rejects an untrusted certificate", tls_untrusted!),
		check!("tls: rejects the wrong server name", tls_wrong_name!),
		check!("tls: full duplex, 1 MB each way at once", tls_full_duplex!),
		check!("tls: STARTTLS upgrade of a TCP connection", tls_starttls!),
		check!("tls: STARTTLS handshake times out if the peer stalls", tls_starttls_stall!),
		check!("tls: handshake deadline beats a peer trickling bytes", tls_trickle!),
		check!("tls: STARTTLS keeps the plain stream's read timeout", tls_starttls_keeps_timeout!),
		check!("tls server: slowloris client times out", tls_server_slowloris!),
		check!("tls server: silent client times out", tls_server_silent!),
		check!("tls server: deadline covers only the handshake", tls_server_deadline_only_handshake!),
		check!("tls server: STARTTLS handshake times out", tls_server_starttls_stall!),
		check!("server: idle tcp client times out", idle_tcp!),
		check!("server: idle unix client times out", idle_unix!),
		check!("server: idle tls client times out after the handshake", idle_tls!),
		check!("server: client that never reads times out a write", write_timeout!),
		check!("framing: line trickled a byte at a time times out", framing_slowloris_line!),
		check!("framing: frame trickled a byte at a time times out", framing_slowloris_frame!),
		check!("framing: idle between lines hands the reader back", framing_idle_resume!),
		check!("framing: timeout mid-line is not idle", framing_idle_mid_line!),
		check!("framing: timeout mid-frame is not idle", framing_idle_mid_frame!),
		check!("read_into!: each read replaces the buffer's contents", read_into_loop!),
		check!("read_into!: a buffer still in use elsewhere is left alone", read_into_shared!),
		check!("read_append!: appends, and end of stream leaves it unchanged", read_append_basic!),
		check!("read_into!: a list literal as the buffer is never written to", read_into_literal!),
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

# Connect without ever accepting until the listener's queue is full. Then
# Linux reports "try again" (the connect retries until its timeout, without
# blocking the thread) and macOS refuses the connection; either way it must
# give up promptly.
unix_backlog_full! = || {
	path = "/tmp/roc-net-tests-backlog.sock"
	listener = Unix.listen!(path)?
	var $held = []
	for _ in U64.until(0, 5000) {
		start = Time.now!()
		result = Unix.connect_timeout!(path, Millis(100))
		took = start.elapsed!().to_millis()
		match result {
			Ok(stream) => {
				$held = List.append($held, stream)
			}
			Err(UnixErr(TimedOut)) | Err(UnixErr(ConnectionRefused)) => {
				# Keep the listener (and the queue) alive until now.
				_ = listener.local_addr!()
				return if took < 2000 Ok({}) else Err(Unexpected("gave up after ${took.to_str()} ms"))
			}
			Err(UnixErr(Other(message))) if Str.contains(message, "os error 24") =>
				return Err(Unexpected("out of file descriptors after ${List.len($held).to_str()} connections, before the queue filled; raise the limit (ulimit -n) above the listener backlog (4,096 on Linux)"))
			Err(other) => return Err(Unexpected("after ${List.len($held).to_str()} connections: ${Str.inspect(other)}"))
		}
	}
	Err(Unexpected("the queue never filled: ${List.len($held).to_str()} connections"))
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

channel_order! = || {
	(tx, rx) = Channel.new!(4)?
	tx.send!("one")?
	tx.send!("two")?
	tx.send!(Str.repeat("three ", 1000))?
	expect_eq([rx.receive!()?, rx.receive!()?, Str.trim(rx.receive!()?)], ["one", "two", Str.trim(Str.repeat("three ", 1000))])
}

## Receive until the channel closes, adding up what arrives.
sum_until_closed! = |rx| {
	var $sum = 0.U64
	var $count = 0.U64
	while True {
		match rx.receive!() {
			Ok(n) => {
				$sum = $sum + n
				$count = $count + 1
			}
			Err(ChannelClosed) => break
		}
	}
	($count, $sum)
}

# The producer's task owns the only sender; when it finishes, the sender is
# released and the consumer's loop ends.
channel_producer_ends! = || {
	(tx, rx) = Channel.new!(8)?
	Task.spawn!(|| {
		for n in U64.until(1, 1001) {
			tx.send!(n)?
		}
		Ok({})
	})?
	expect_eq(sum_until_closed!(rx), (1000, 500500))
}

channel_many_producers! = || {
	(tx, rx) = Channel.new!(8)?
	for producer in U64.until(0, 4) {
		Task.spawn!(|| {
			for n in U64.until(0, 250) {
				tx.send!(producer * 250 + n)?
			}
			Ok({})
		})?
	}
	expect_eq(sum_until_closed!(rx), (1000, 499500))
}

# With room for one value, the producer has to wait for the consumer for
# every value but the first.
channel_backpressure! = || {
	(tx, rx) = Channel.new!(1)?
	Task.spawn!(|| {
		for n in U64.until(0, 200) {
			tx.send!(n)?
		}
		Ok({})
	})?
	var $expected = 0.U64
	while True {
		match rx.receive!() {
			Ok(n) => {
				if n != $expected {
					return Err(Unexpected("got ${n.to_str()}, expected ${$expected.to_str()}"))
				}
				$expected = $expected + 1
			}
			Err(ChannelClosed) => break
		}
	}
	expect_eq($expected, 200)
}

channel_non_blocking! = || {
	(tx, rx) = Channel.new!(2)?
	expect_eq(rx.try_receive!(), Err(ChannelEmpty))?
	tx.try_send!(1)?
	tx.try_send!(2)?
	expect_eq(tx.try_send!(3), Err(ChannelFull))?
	expect_eq(rx.try_receive!(), Ok(1))?
	expect_eq(rx.receive_timeout!(Time.millis(50)), Ok(2))?
	start = Time.now!()
	expect_eq(rx.receive_timeout!(Time.millis(50)), Err(TimedOut))?
	waited = start.elapsed!().to_millis()
	# Using the sender here keeps it alive until now. Released earlier, it
	# would close the channel, and the receive above would rightly report
	# ChannelClosed instead of waiting out the timeout.
	tx.close!()
	if waited >= 50 and waited < 1000 Ok({}) else Err(Unexpected("timed out after ${waited.to_str()} ms"))
}

channel_close! = || {
	(tx, rx) = Channel.new!(4)?
	tx.send!("queued")?
	tx.close!()
	expect_eq(tx.send!("too late"), Err(ChannelClosed))?
	expect_eq(rx.receive!(), Ok("queued"))?
	expect_eq(rx.receive!(), Err(ChannelClosed))
}

channel_receiver_gone! = || {
	tx = sender_only!()?
	expect_eq(tx.send!(1), Err(ChannelClosed))
}

## A channel's sender, with its receiver released when this returns.
sender_only! = || {
	(tx, _) = Channel.new!(4)?
	Ok(tx)
}

# A server task answers each request on the reply channel sent with it.
channel_reply! = || {
	(requests, incoming) = Channel.new!(4)?
	Task.spawn!(|| {
		while True {
			match incoming.receive!() {
				Ok((n, reply)) => reply.send!(n * 2)?
				Err(ChannelClosed) => break
			}
		}
		Ok({})
	})?
	(reply_tx, reply_rx) = Channel.new!(1)?
	requests.send!((21, reply_tx))?
	expect_eq(reply_rx.receive!(), Ok(42))
}

# A connection left queued in a channel is closed when the channel goes away,
# so the other end sees the end of the stream instead of waiting forever.
channel_frees_values! = || {
	(listener, address) = listen_anywhere!()?
	client = Tcp.connect!(address)?
	client.set_read_timeout!(Millis(2000))?
	strand!(listener.accept!()?)?
	match client.read!(16) {
		Ok([]) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

## Queue `stream` behind a marker, take only the marker, and let both ends go.
strand! = |stream| {
	(tx, rx) = Channel.new!(2)?
	tx.send!(Marker)?
	tx.send!(Conn(stream))?
	match rx.receive!()? {
		Marker => Ok({})
		Conn(_) => Err(Unexpected("received the stream before the marker"))
	}
}

# TLS tests use the certificates in examples/net_tests/certs (made by
# scripts/make_test_certs.sh), so run them from the repository root.
test_ca = "examples/net_tests/certs/ca.pem"
test_server_cert = Tls.server_config({ cert_file: "examples/net_tests/certs/server.pem", key_file: "examples/net_tests/certs/server-key.pem" })
trusting_test_ca = Tls.client_config.with_ca_file(test_ca)

tls_listen_anywhere! = || {
	listener = Tls.listen!("127.0.0.1:0", test_server_cert)?
	address = listener.local_addr!()?
	Ok((listener, address))
}

# `serve_length!` and `exchange!` were written for TCP and Unix streams.
tls_round_trip! = || {
	(listener, address) = tls_listen_anywhere!()?
	serve_length!(listener)?
	client = Tls.connect_with!(address, trusting_test_ca)?
	expect_eq(exchange!(client, "hello over tls")?, "got 14 bytes")
}

## A TLS server that accepts one connection and waits for it to end, ignoring
## errors (the client is expected to abandon the handshake).
tls_serve_quietly! = |listener|
	Task.spawn!(|| {
		stream = listener.accept!()?
		_ = stream.read!(16)
		Ok({})
	})

expect_tls_rejected! = |result, reason| {
	match result {
		Err(TlsErr(Other(message))) if Str.contains(message, reason) => Ok({})
		other => Err(Unexpected("expected a rejection mentioning ${reason}, got ${Str.inspect(other)}"))
	}
}

# Mozilla's roots don't include the test CA.
tls_untrusted! = || {
	(listener, address) = tls_listen_anywhere!()?
	tls_serve_quietly!(listener)?
	expect_tls_rejected!(Tls.connect!(address), "UnknownIssuer")
}

# The certificate is for localhost and 127.0.0.1, not example.com.
tls_wrong_name! = || {
	(listener, address) = tls_listen_anywhere!()?
	tls_serve_quietly!(listener)?
	expect_tls_rejected!(Tls.connect_with!(address, trusting_test_ca.with_server_name("example.com")), "not valid for name")
}

# One task sends 1 MB while this one reads the echo at the same time. If the
# two directions blocked each other, the buffers would fill and this would
# hang (the read timeout turns that into a failure).
tls_full_duplex! = || {
	(listener, address) = tls_listen_anywhere!()?
	Task.spawn!(|| {
		stream = listener.accept!()?
		while True {
			bytes = stream.read!(16384)?
			if List.is_empty(bytes) {
				break
			}
			stream.write!(bytes)?
		}
		Ok({})
	})?

	client = Tls.connect_with!(address, trusting_test_ca)?
	client.set_read_timeout!(Millis(10000))?
	chunk = List.repeat(42, 16384)
	Task.spawn!(|| {
		for _ in U64.until(0, 64) {
			client.write!(chunk)?
		}
		client.shutdown!(Write)
	})?
	var $received = 0
	var $all_42 = True
	while True {
		bytes = client.read!(65536)?
		if List.is_empty(bytes) {
			break
		}
		$received = $received + List.len(bytes)
		if List.any(bytes, |b| b != 42) {
			$all_42 = False
		}
	}
	expect_eq(($received, $all_42), (1048576, True))
}

# Plain TCP until the client asks to upgrade, then TLS on the same connection.
tls_starttls! = || {
	(listener, address) = listen_anywhere!()?
	Task.spawn!(|| {
		plain = listener.accept!()?
		expect_eq(Str.from_utf8_lossy(plain.read!(64)?), "STARTTLS\n")?
		plain.write_str!("GO\n")?
		secure = Tls.wrap_server!(plain, test_server_cert)?
		request = read_to_end!(secure)?
		secure.write_str!("secure: ${request}")
	})?

	plain = Tcp.connect!(address)?
	plain.write_str!("STARTTLS\n")?
	expect_eq(Str.from_utf8_lossy(plain.read!(64)?), "GO\n")?
	secure = Tls.wrap_client!(plain, trusting_test_ca.with_server_name("localhost"))?
	expect_eq(exchange!(secure, "hi")?, "secure: hi")
}

## Fail unless `took` was at least `min_ms` and well under a hang.
expect_duration = |took, min_ms| {
	ms = took.to_millis()
	if ms >= min_ms and ms < min_ms + 3000 Ok({}) else Err(Unexpected("took ${ms.to_str()} ms"))
}

## Accept one plain connection, agree to STARTTLS, then never speak TLS:
## just read (and ignore) whatever arrives until the client hangs up.
serve_starttls_then_stall! = |listener|
	Task.spawn!(|| {
		plain = listener.accept!()?
		_ = plain.read!(64)?
		plain.write_str!("GO\n")?
		while True {
			match plain.read!(4096) {
				Ok([]) | Err(_) => break
				Ok(_) => {}
			}
		}
		Ok({})
	})

# Without the timeout reaching the handshake, this waited forever.
tls_starttls_stall! = || {
	(listener, address) = listen_anywhere!()?
	serve_starttls_then_stall!(listener)?

	plain = Tcp.connect!(address)?
	plain.write_str!("STARTTLS\n")?
	_ = plain.read!(64)?
	start = Time.now!()
	config = trusting_test_ca.with_server_name("localhost").with_timeout(Millis(300))
	match Tls.wrap_client!(plain, config) {
		Err(TlsErr(TimedOut)) => expect_duration(start.elapsed!(), 300)
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# The server starts a TLS record that claims 16 KB and then sends one byte
# every 50 ms. Each read gets a byte in time, so only a deadline for the whole
# handshake stops it (otherwise it would take about 13 minutes).
tls_trickle! = || {
	(listener, address) = listen_anywhere!()?
	Task.spawn!(|| {
		stream = listener.accept!()?
		# Handshake record, TLS 1.2 version field, length 16384.
		stream.write!([22, 3, 3, 64, 0])?
		for _ in U64.until(0, 16384) {
			Time.sleep!(Time.millis(50))
			match stream.write!([0]) {
				Ok({}) => {}
				Err(_) => break
			}
		}
		Ok({})
	})?

	start = Time.now!()
	match Tls.connect_with!(address, trusting_test_ca.with_timeout(Millis(500))) {
		Err(TlsErr(TimedOut)) => expect_duration(start.elapsed!(), 500)
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# A read timeout set before the upgrade still applies afterwards, even though
# the handshake used its own deadline in between.
tls_starttls_keeps_timeout! = || {
	(listener, address) = listen_anywhere!()?
	Task.spawn!(|| {
		plain = listener.accept!()?
		_ = plain.read!(64)?
		plain.write_str!("GO\n")?
		secure = Tls.wrap_server!(plain, test_server_cert)?
		# Handshake, then say nothing until the client hangs up.
		_ = read_to_end!(secure)
		Ok({})
	})?

	plain = Tcp.connect!(address)?
	plain.set_read_timeout!(Millis(200))?
	plain.write_str!("STARTTLS\n")?
	_ = plain.read!(64)?
	secure = Tls.wrap_client!(plain, trusting_test_ca.with_server_name("localhost"))?
	start = Time.now!()
	match secure.read!(16) {
		Err(TlsErr(TimedOut)) => expect_duration(start.elapsed!(), 200)
		other => Err(Unexpected(Str.inspect(other)))
	}
}

## A TLS server whose clients get 300 ms to finish the handshake. It accepts
## one connection, tries one read, and reports what happened (and how long
## after accepting) on the returned channel.
tls_impatient_server! = || {
	listener = Tls.listen!("127.0.0.1:0", test_server_cert.with_handshake_timeout(Millis(300)))?
	address = listener.local_addr!()?
	(report, outcome) = Channel.new!(1)?
	Task.spawn!(|| {
		stream = listener.accept!()?
		accepted = Time.now!()
		result = stream.read!(64)
		report.send!((result, accepted.elapsed!()))
	})?
	Ok((address, outcome))
}

expect_server_timed_out = |(result, took)|
	match result {
		Err(TlsErr(TimedOut)) => expect_duration(took, 300)
		other => Err(Unexpected(Str.inspect(other)))
	}

# The client starts a TLS record claiming 16 KB, then sends a byte every
# 50 ms: every read the server makes succeeds in time, so only a deadline
# for the whole handshake ends it.
tls_server_slowloris! = || {
	(address, outcome) = tls_impatient_server!()?
	attacker = Tcp.connect!(address)?
	Task.spawn!(|| {
		attacker.write!([22, 3, 3, 64, 0])?
		for _ in U64.until(0, 16384) {
			Time.sleep!(Time.millis(50))
			match attacker.write!([0]) {
				Ok({}) => {}
				Err(_) => break
			}
		}
		Ok({})
	})?
	expect_server_timed_out(outcome.receive_timeout!(Time.seconds(5))?)
}

tls_server_silent! = || {
	(address, outcome) = tls_impatient_server!()?
	silent = Tcp.connect!(address)?
	reported = outcome.receive_timeout!(Time.seconds(5))?
	# Keep the silent connection open until the server has given up on it.
	silent.close!()
	expect_server_timed_out(reported)
}

# A client that finishes the handshake at once and then waits longer than
# the handshake deadline before sending is served normally.
tls_server_deadline_only_handshake! = || {
	(address, outcome) = tls_impatient_server!()?
	client = Tls.connect_with!(address, trusting_test_ca)?
	Time.sleep!(Time.millis(700))
	client.write_str!("late but fine")?
	match outcome.receive_timeout!(Time.seconds(5))? {
		(Ok(bytes), _) => expect_eq(Str.from_utf8_lossy(bytes), "late but fine")
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# The client agrees to STARTTLS but never starts the handshake.
tls_server_starttls_stall! = || {
	(listener, address) = listen_anywhere!()?
	(report, outcome) = Channel.new!(1)?
	Task.spawn!(|| {
		plain = listener.accept!()?
		_ = plain.read!(64)?
		plain.write_str!("GO\n")?
		upgraded = Time.now!()
		secure = Tls.wrap_server!(plain, test_server_cert.with_handshake_timeout(Millis(300)))?
		result = secure.read!(64)
		report.send!((result, upgraded.elapsed!()))
	})?
	client = Tcp.connect!(address)?
	client.write_str!("STARTTLS\n")?
	_ = client.read!(64)?
	reported = outcome.receive_timeout!(Time.seconds(5))?
	client.close!()
	expect_server_timed_out(reported)
}

## Serve `writes` over TCP to a reader limited to 10 bytes, each as its own
## write a moment apart (so they arrive as separate reads), and return the
## reader.
limited_reader! = |writes| {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| {
		for chunk in writes {
			stream.write_str!(chunk)?
			Time.sleep!(Time.millis(50))
		}
		Ok({})
	})?
	Ok(Framing.reader_with_max(Tcp.connect!(address)?, 10))
}

# The whole over-long line and its newline arrive together.
framing_limit_single_read! = || {
	reader = limited_reader!(["this line is way too long\nok\n"])?
	match reader.read_line!() {
		Err(TooLong) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

framing_limit_boundary! = || {
	whole = limited_reader!(["0123456789\n"])?
	(line, _) = whole.read_line!()?
	expect_eq(line, "0123456789")?
	# Ten bytes, then the newline in a later read.
	split = limited_reader!(["0123456789", "\n"])?
	(split_line, _) = split.read_line!()?
	expect_eq(split_line, "0123456789")?
	# Eleven bytes is too long either way.
	over = limited_reader!(["01234567890", "\n"])?
	match over.read_line!() {
		Err(TooLong) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

framing_limit_exactly! = || {
	reader = limited_reader!(["01234567890123456789"])?
	match reader.read_exactly!(11) {
		Err(TooLong) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# Timeouts too long to represent as a moment in time used to panic the host
# (aborting the program). Now they cap, which works out as no limit.
huge_timeouts! = || {
	expect_eq(Time.seconds(U64.highest).to_nanos(), U64.highest)?
	expect_eq(Time.millis(U64.highest).plus(Time.seconds(1)).to_nanos(), U64.highest)?

	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| stream.write_str!("hi"))?
	_ = Tcp.connect_timeout!(address, Millis(U64.highest))?

	# A full exchange, so the server's task ends normally: a client that left
	# right after connecting could make it fail sending the session tickets
	# TLS 1.3 servers send after the handshake (BrokenPipe on Linux).
	(tls_listener, tls_address) = tls_listen_anywhere!()?
	serve_length!(tls_listener)?
	client = Tls.connect_with!(tls_address, trusting_test_ca.with_timeout(Millis(U64.highest)))?
	expect_eq(exchange!(client, "ping")?, "got 4 bytes")?

	_ = Dns.resolve_timeout!("localhost", Millis(U64.highest))?

	(tx, rx) = Channel.new!(1)?
	tx.send!("queued")?
	expect_eq(rx.receive_timeout!(Time.seconds(U64.highest)), Ok("queued"))
}

# The limit is on frame payloads, not the 4-byte header, so a reader limited
# to 3 bytes still reads frames of 0 to 3 bytes, and rejects a 4-byte one.
framing_limit_small_frames! = || {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| {
		Framing.write_frame!(stream, [])?
		Framing.write_frame!(stream, [1, 2, 3])?
		Framing.write_frame!(stream, [1, 2, 3, 4])
	})?
	reader = Framing.reader_with_max(Tcp.connect!(address)?, 3)
	(empty, r1) = reader.read_frame!()?
	(three, r2) = r1.read_frame!()?
	expect_eq((empty, three), ([], [1, 2, 3]))?
	match r2.read_frame!() {
		Err(TooLong) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

## Run `serve!` on the next accepted stream in a task and send back its result
## and how long it took, measured from accept.
report_from_server! = |accept!, serve!| {
	(report, outcome) = Channel.new!(1)?
	Task.spawn!(|| {
		stream = accept!()?
		accepted = Time.now!()
		result = serve!(stream)
		report.send!((Str.inspect(result), accepted.elapsed!()))
	})?
	Ok(outcome)
}

## The server's result must mention `expected` and have taken at least
## `min_ms` (and not so long it looks like a hang).
expect_report = |(result, took), expected, min_ms|
	if Str.contains(result, expected) {
		expect_duration(took, min_ms)
	} else {
		Err(Unexpected("expected ${expected}, got ${result}"))
	}

quick_idle = Tcp.listen_config.with_idle_timeout(Millis(200))

idle_tcp! = || {
	listener = Tcp.listen_with!("127.0.0.1:0", quick_idle)?
	address = listener.local_addr!()?
	outcome = report_from_server!(|| listener.accept!(), |stream| stream.read!(16))?
	silent = Tcp.connect!(address)?
	reported = outcome.receive_timeout!(Time.seconds(5))?
	silent.close!()
	expect_report(reported, "TimedOut", 200)
}

idle_unix! = || {
	path = "/tmp/roc-net-tests-idle.sock"
	listener = Unix.listen_with!(path, Unix.listen_config.with_idle_timeout(Millis(200)))?
	outcome = report_from_server!(|| listener.accept!(), |stream| stream.read!(16))?
	silent = Unix.connect!(path)?
	reported = outcome.receive_timeout!(Time.seconds(5))?
	silent.close!()
	expect_report(reported, "TimedOut", 200)
}

# The handshake completes, then the client says nothing.
idle_tls! = || {
	listener = Tls.listen!("127.0.0.1:0", test_server_cert.with_idle_timeout(Millis(200)))?
	address = listener.local_addr!()?
	outcome = report_from_server!(|| listener.accept!(), |stream| stream.read!(16))?
	silent = Tls.connect_with!(address, trusting_test_ca)?
	reported = outcome.receive_timeout!(Time.seconds(5))?
	silent.close!()
	expect_report(reported, "TimedOut", 200)
}

# The client never reads, so once the connection's buffers fill, the server's
# writes block until the write timeout.
write_timeout! = || {
	listener = Tcp.listen_with!("127.0.0.1:0", Tcp.listen_config.with_write_timeout(Millis(200)))?
	address = listener.local_addr!()?
	chunk = List.repeat(7, 65536)
	outcome = report_from_server!(
		|| listener.accept!(),
		|stream| {
			while True {
				stream.write!(chunk)?
			}
			Ok({})
		},
	)?
	not_reading = Tcp.connect!(address)?
	reported = outcome.receive_timeout!(Time.seconds(10))?
	not_reading.close!()
	match reported {
		(result, _) if Str.contains(result, "TimedOut") => Ok({})
		(result, _) => Err(Unexpected(result))
	}
}

## Send `prefix`, then one byte every 50 ms until the connection breaks.
trickle! = |address, prefix, byte| {
	client = Tcp.connect!(address)?
	Task.spawn!(|| {
		client.write!(prefix)?
		for _ in U64.until(0, 1000) {
			Time.sleep!(Time.millis(50))
			match client.write!([byte]) {
				Ok({}) => {}
				Err(_) => break
			}
		}
		Ok({})
	})
}

# Every read gets a byte in time, so the idle timeout never fires; only the
# message timeout catches it.
framing_slowloris_line! = || {
	(listener, address) = listen_anywhere!()?
	outcome = report_from_server!(
		|| listener.accept!(),
		|stream| Framing.reader(stream).with_message_timeout(Millis(300)).read_line!(),
	)?
	trickle!(address, [], 97)?
	expect_report(outcome.receive_timeout!(Time.seconds(5))?, "MessageTimedOut", 300)
}

# A frame announcing 16 bytes whose payload trickles in.
framing_slowloris_frame! = || {
	(listener, address) = listen_anywhere!()?
	outcome = report_from_server!(
		|| listener.accept!(),
		|stream| Framing.reader(stream).with_message_timeout(Millis(300)).read_frame!(),
	)?
	trickle!(address, [0, 0, 0, 16], 1)?
	expect_report(outcome.receive_timeout!(Time.seconds(5))?, "MessageTimedOut", 300)
}

## A listener whose accepted streams time out reads after 200 ms of silence.
quick_idle_listener! = || {
	listener = Tcp.listen_with!("127.0.0.1:0", quick_idle)?
	address = listener.local_addr!()?
	Ok((listener, address))
}

# The client stays quiet until pinged. The server's read goes idle, it pings
# with the handed-back reader, and reads the reply with it.
framing_idle_resume! = || {
	(listener, address) = quick_idle_listener!()?
	outcome = report_from_server!(
		|| listener.accept!(),
		|stream| {
			match Framing.reader(stream).read_line!() {
				Err(Idle(same)) => {
					stream.write_str!("PING\n")?
					(reply, _) = same.read_line!()?
					Ok(reply)
				}
				other => Err(Unexpected(Str.inspect(other)))
			}
		},
	)?
	client = Tcp.connect!(address)?
	client.set_read_timeout!(Millis(5000))?
	(ping, _) = Framing.reader(client).read_line!()?
	expect_eq(ping, "PING")?
	client.write_str!("PONG\n")?
	expect_report(outcome.receive_timeout!(Time.seconds(5))?, "Ok(\"PONG\")", 200)
}

## Send `bytes` and then say nothing more (until the server has reported).
send_then_stall! = |address, bytes, outcome| {
	client = Tcp.connect!(address)?
	client.write!(bytes)?
	reported = outcome.receive_timeout!(Time.seconds(5))?
	client.close!()
	Ok(reported)
}

framing_idle_mid_line! = || {
	(listener, address) = quick_idle_listener!()?
	outcome = report_from_server!(|| listener.accept!(), |stream| Framing.reader(stream).read_line!())?
	reported = send_then_stall!(address, Str.to_utf8("partial"), outcome)?
	match reported {
		(result, _) if Str.contains(result, "TcpErr(TimedOut)") => Ok({})
		(result, _) => Err(Unexpected(result))
	}
}

# The header announces 8 bytes, then nothing: the buffer is empty when the
# read times out, but the frame has started, so this isn't idle.
framing_idle_mid_frame! = || {
	(listener, address) = quick_idle_listener!()?
	outcome = report_from_server!(|| listener.accept!(), |stream| Framing.reader(stream).read_frame!())?
	reported = send_then_stall!(address, [0, 0, 0, 8], outcome)?
	match reported {
		(result, _) if Str.contains(result, "TcpErr(TimedOut)") => Ok({})
		(result, _) => Err(Unexpected(result))
	}
}

## A server that sends each of `messages` as its own write, a moment apart,
## then hangs up; returns the client's stream.
messages_from_server! = |messages| {
	(listener, address) = listen_anywhere!()?
	serve_once!(listener, |stream| {
		for message in messages {
			stream.write_str!(message)?
			Time.sleep!(Time.millis(30))
		}
		Ok({})
	})?
	Tcp.connect!(address)
}

read_into_loop! = || {
	stream = messages_from_server!(["first", "second message", "3"])?
	var $buf = List.with_capacity(64)
	var $got = []
	while True {
		$buf = stream.read_into!($buf, 64)?
		if List.is_empty($buf) {
			break
		}
		$got = List.append($got, Str.from_utf8_lossy($buf))
	}
	expect_eq($got, ["first", "second message", "3"])
}

# Keeping the first result while reading again must not change it: the host
# has to see the buffer is shared and use a new one.
read_into_shared! = || {
	stream = messages_from_server!(["aaaa", "bbbb"])?
	first = stream.read_into!(List.with_capacity(64), 64)?
	second = stream.read_into!(first, 64)?
	expect_eq((Str.from_utf8_lossy(first), Str.from_utf8_lossy(second)), ("aaaa", "bbbb"))
}

read_append_basic! = || {
	stream = messages_from_server!(["ab", "cd"])?
	one = stream.read_append!(Str.to_utf8("start:"), 64)?
	two = stream.read_append!(one, 64)?
	three = stream.read_append!(two, 64)?
	expect_eq((Str.from_utf8_lossy(two), List.len(three) == List.len(two)), ("start:abcd", True))
}

# A literal list lives in the program's read-only data. The host must not
# treat it as reusable (its refcount marks it as static, which "unique"
# checks can mistake for unique).
read_into_literal! = || {
	stream = messages_from_server!(["xy"])?
	literal = [1, 2, 3, 4, 5, 6, 7, 8]
	got = stream.read_into!(literal, 64)?
	expect_eq((got, literal), ([120, 121], [1, 2, 3, 4, 5, 6, 7, 8]))
}
