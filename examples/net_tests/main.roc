app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Bytes
import pf.Channel
import pf.Dns
import pf.Framing
import pf.Random
import pf.Select
import pf.Stdout
import pf.Stream
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
		check!("select: the channel that gets a value wins", select_channel_wins!),
		check!("select: timeout when nothing happens", select_timeout!),
		check!("select: a closed peer is an empty read", select_read_closed!),
		check!("select: the losing arm's value stays queued", select_loser_keeps_value!),
		check!("select: ready arms take turns", select_fairness!),
		check!("select: accept, and room to send", select_accept_and_send!),
		check!("select: TLS data already decrypted counts as ready", select_tls_buffered!),
		check!("select: cancelling the task ends the wait", select_cancelled!),
		check!("select: Framing lines, split and buffered", select_lines!),
		check!("select: Framing frames", select_frames!),
		check!("task: join returns the result, more than once", task_join!),
		check!("task: join returns the task's error", task_join_error!),
		check!("task: cancel wakes a blocked read and closes its socket", task_cancel_read!),
		check!("task: cancel wakes sleep and receive", task_cancel_sleep_receive!),
		check!("task: cancelling a finished task changes nothing", task_cancel_finished!),
		check!("scope: waits for its tasks when the body succeeds", scope_waits!),
		check!("scope: a failing body cancels the rest", scope_cancels_on_error!),
		check!("scope: nested scopes", scope_nested!),
		check!("task: is_cancelled! for a computation", task_is_cancelled!),
		check!("task: a sleep loop stops when cancelled", task_cancel_sleep_loop!),
		check!("channel: a cancelled receiver doesn't swallow a value", channel_cancelled_waiter!),
		check!("select: a TLS peer that never shakes hands doesn't block it", select_tls_silent_peer!),
		check!("select: a server TLS stream shakes hands while polling", select_tls_server_handshake!),
		check!("select: the TLS handshake deadline ends a wait with no timeout", select_tls_handshake_deadline!),
		check!("select: a stream's read timeout ends a wait with no timeout", select_read_timeout!),
		check!("select: two selects on one stream each get their own timeout", select_timeouts_per_select!),
		check!("select: TLS data left by another reader wakes it", select_tls_after_other_reader!),
		check!("select: watching a stream mid-handshake doesn't block the handshake", select_during_handshake!),
		check!("tls: a server that speaks first, with a reader running the handshake", tls_server_speaks_first!),
		check!("tls: handshake! finishes a server stream's handshake", tls_explicit_handshake!),
		check!("tls: handshake! reports a failed handshake", tls_explicit_handshake_fails!),
		check!("tls: a missing certificate file names the file", tls_missing_cert!),
		check!("tls: a key that doesn't match the certificate says so", tls_mismatched_key!),
		check!("shutdown!: succeeds after the peer closed (tcp, tls)", shutdown_after_peer_closed!),
		check!("scope: a failing task doesn't stop the others", scope_child_fails!),
		check!("scope: stop them all when the first one ends", scope_first_ends!),
		check!("tls sni: a certificate by exact name, wildcard, or the default", tls_sni_picks_cert!),
		check!("tls sni: server_name! reports the requested name", tls_sni_server_name!),
		check!("tls sni: a certificate name must be a DNS name", tls_sni_bad_name!),
		check!("tls alpn: the server's preference among the client's offers", tls_alpn_agrees!),
		check!("tls alpn: no common protocol fails the handshake", tls_alpn_no_overlap!),
		check!("tls alpn: a client offering none gets none", tls_alpn_client_offers_none!),
		check!("copy_both!: tcp to tcp, with a half-close passed on", copy_both_tcp!),
		check!("copy_both!: tls client to a tcp backend", copy_both_tls_to_tcp!),
		check!("copy_both!: a one-way download isn't idle", copy_both_one_way!),
		check!("copy_both!: idle both ways times out", copy_both_idle!),
		check!("copy_both!: cancelling stops both directions", copy_both_cancelled!),
		check!("copy_both!: a backend reset mid-response reaches a tls client as an error", copy_both_reset_tls!),
		check!("copy_both!: a backend reset mid-response reaches a tcp client as a reset", copy_both_reset_tcp!),
		check!("copy_both!: a write to a slow reader isn't idle", copy_both_slow_reader!),
		check!("abort!: the peer sees an error, not a clean end (tcp, tls)", abort_is_not_clean!),
		check!("copy_both!: many small exchanges at once, across threads", copy_both_many_sessions!),
		check!("copy_both!: unix to unix, and unix to tcp", copy_both_unix!),
		check!("stream: a where clause over any stream, and mixed listeners", stream_generic!),
		check!("select: on_join, the first task to finish wins", select_join_first!),
		check!("select: on_join, a finished task is ready at once", select_join_finished!),
		check!("select: on_join with a timeout, and the loser's result kept", select_join_timeout!),
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		request = read_to_end!(stream)?
		stream.write_str!("got ${Str.count_utf8_bytes(request).to_str()} bytes")
	})?
	Ok({})
}

unix_round_trip! = || {
	path = "/tmp/roc-net-tests-round-trip.sock"
	listener = Unix.listen!(path)?
	expect_eq(listener.local_addr!()?, path)?
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
		received = server.recv_from!(1024)?
		server.send_to!(received.bytes, received.from)
	})?
	Ok({})
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
serve_once! = |listener, send!| {
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.set_nodelay!(True)?
		send!(stream)
	})?
	Ok({})
}

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
	Time.sleep!(Time.millis(50))?
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
			Err(ChannelClosed) | Err(Cancelled) => break
		}
	}
	($count, $sum)
}

# The producer's task owns the only sender; when it finishes, the sender is
# released and the consumer's loop ends.
channel_producer_ends! = || {
	(tx, rx) = Channel.new!(8)?
	_ = Task.spawn!(|| {
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
		_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
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
			Err(ChannelClosed) | Err(Cancelled) => break
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
	_ = Task.spawn!(|| {
		while True {
			match incoming.receive!() {
				Ok((n, reply)) => reply.send!(n * 2)?
				Err(ChannelClosed) | Err(Cancelled) => break
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
tls_serve_quietly! = |listener| {
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		_ = stream.read!(16)
		Ok({})
	})?
	Ok({})
}

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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
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
serve_starttls_then_stall! = |listener| {
	_ = Task.spawn!(|| {
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
	})?
	Ok({})
}

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
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		# Handshake record, TLS 1.2 version field, length 16384.
		stream.write!([22, 3, 3, 64, 0])?
		for _ in U64.until(0, 16384) {
			Time.sleep!(Time.millis(50))?
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
		attacker.write!([22, 3, 3, 64, 0])?
		for _ in U64.until(0, 16384) {
			Time.sleep!(Time.millis(50))?
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
	Time.sleep!(Time.millis(700))?
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
	_ = Task.spawn!(|| {
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
			Time.sleep!(Time.millis(50))?
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
	_ = Task.spawn!(|| {
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
	_ = Task.spawn!(|| {
		client.write!(prefix)?
		for _ in U64.until(0, 1000) {
			Time.sleep!(Time.millis(50))?
			match client.write!([byte]) {
				Ok({}) => {}
				Err(_) => break
			}
		}
		Ok({})
	})?
	Ok({})
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
			Time.sleep!(Time.millis(30))?
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

# --- Select ---

select_channel_wins! = || {
	(texts_tx, texts) = Channel.new!(1)?
	(numbers_tx, numbers) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		Time.sleep!(Time.millis(20))?
		numbers_tx.send!(42.U64)
	})?
	got = Select.new({})
		.on_receive(texts, |result| Text(result))
		.on_receive(numbers, |result| Number(result))
		.wait!()?
	# Keep the text sender alive until now, so that channel isn't closed.
	texts_tx.close!()
	expect_eq(got, Number(Ok(42)))
}

select_timeout! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		Time.sleep!(Time.seconds(2))?
		stream.write_str!("too late")
	})?
	client = Tcp.connect!(address)?
	start = Time.now!()
	got = Select.new({})
		.on_read(client, 100, |result| Read(result))
		.on_timeout(Time.millis(100), || Idle)
		.wait!()?
	took = start.elapsed!().to_millis()
	expect_eq(got, Idle)?
	if took >= 90 and took < 1000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

select_read_closed! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.close!()
		Ok({})
	})?
	client = Tcp.connect!(address)?
	got = Select.new({})
		.on_read(client, 100, |result| Read(result))
		.on_timeout(Time.seconds(5), || Idle)
		.wait!()?
	expect_eq(got, Read(Ok([])))
}

select_loser_keeps_value! = || {
	(a_tx, a) = Channel.new!(1)?
	(b_tx, b) = Channel.new!(1)?
	a_tx.send!("a")?
	b_tx.send!("b")?
	got = Select.new({})
		.on_receive(a, |result| result)
		.on_receive(b, |result| result)
		.wait!()?
	# Whichever lost still has its value.
	other = if got == Ok("a") b.try_receive!() else a.try_receive!()
	match (got, other) {
		(Ok("a"), Ok("b")) | (Ok("b"), Ok("a")) => Ok({})
		_ => Err(Unexpected(Str.inspect((got, other))))
	}
}

select_fairness! = || {
	(a_tx, a) = Channel.new!(200)?
	(b_tx, b) = Channel.new!(200)?
	for n in U64.until(0, 200) {
		a_tx.send!(n)?
		b_tx.send!(n)?
	}
	var $a_wins = 0.U64
	for _ in U64.until(0, 100) {
		got = Select.new({})
			.on_receive(a, |_| A)
			.on_receive(b, |_| B)
			.wait!()?
		if got == A {
			$a_wins = $a_wins + 1
		}
	}
	if $a_wins >= 10 and $a_wins <= 90 Ok({}) else Err(Unexpected("a won ${$a_wins.to_str()} of 100"))
}

select_accept_and_send! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		Time.sleep!(Time.millis(20))?
		_ = Tcp.connect!(address)?
		Ok({})
	})?
	accepted = Select.new({})
		.on_accept(listener, |result| Accepted(result))
		.on_timeout(Time.seconds(5), || Idle)
		.wait!()?
	match accepted {
		Accepted(Ok(_)) => {}
		other => return Err(Unexpected(Str.inspect(other)))
	}
	# A full channel: the send arm wins once the receiver makes room.
	(tx, rx) = Channel.new!(1)?
	tx.send!("first")?
	_ = Task.spawn!(|| {
		Time.sleep!(Time.millis(20))?
		_ = rx.receive!()?
		_ = rx.receive!()?
		Ok({})
	})?
	sent = Select.new({})
		.on_send(tx, "second", |result| Sent(result))
		.on_timeout(Time.seconds(5), || Idle)
		.wait!()?
	expect_eq(sent, Sent(Ok({})))
}

# One TLS record carries 8 bytes; reading 4 at a time leaves 4 decrypted in
# the stream, with nothing more on the socket. The second select must still
# see them as ready.
select_tls_buffered! = || {
	(listener, address) = tls_listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.write_str!("12345678")?
		Time.sleep!(Time.seconds(2))?
		Ok({})
	})?
	client = Tls.connect_with!(address, trusting_test_ca)?
	read_4! = || Select.new({})
		.on_read(client, 4, |result| Read(result))
		.on_timeout(Time.seconds(1), || Idle)
		.wait!()
	first = read_4!()?
	second = read_4!()?
	expect_eq((first, second), (Read(Ok(Str.to_utf8("1234"))), Read(Ok(Str.to_utf8("5678")))))
}

select_cancelled! = || {
	(tx, rx) = Channel.new!(1)?
	handle = Task.spawn!(|| {
		result = Select.new({})
			.on_receive(rx, |r| r)
			.wait!()
		match result {
			Err(Cancelled) => Ok("cancelled")
			other => Ok(Str.inspect(other))
		}
	})?
	Time.sleep!(Time.millis(20))?
	handle.cancel!()
	result = handle.join!()
	# Kept open until now, so the select was waiting, not seeing it closed.
	tx.close!()
	expect_eq(result, Ok("cancelled"))
}

# --- Task handles, cancellation, scopes ---

task_join! = || {
	handle = Task.spawn!(|| {
		Time.sleep!(Time.millis(10))?
		Ok(42.U64)
	})?
	first = handle.join!()?
	second = handle.join!()?
	expect_eq((first, second), (42, 42))
}

## `Err(Boom(message))`, unless `message` is empty: an error the compiler
## can't see coming.
fail_unless_empty = |message|
	if Str.is_empty(message) Ok({}) else Err(Boom(message))

task_join_error! = || {
	handle = Task.spawn!(|| fail_unless_empty("nope"))?
	expect_eq(handle.join!(), Err(Boom("nope")))
}

task_cancel_read! = || {
	(listener, address) = listen_anywhere!()?
	(report_tx, report) = Channel.new!(1)?
	# The server reports what its end sees after the client's reader is
	# cancelled: end of stream, since the cancelled task's socket closes.
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		bytes = stream.read!(100)?
		report_tx.send!(List.len(bytes))
	})?
	reader = Task.spawn!(|| {
		client = Tcp.connect!(address)?
		_ = client.read!(100)?
		Ok({})
	})?
	Time.sleep!(Time.millis(50))?
	reader.cancel!()
	match reader.join!() {
		Err(TcpErr(Cancelled)) => {}
		other => return Err(Unexpected(Str.inspect(other)))
	}
	expect_eq(report.receive_timeout!(Time.seconds(5)), Ok(0))
}

task_cancel_sleep_receive! = || {
	sleeper = Task.spawn!(|| {
		Time.sleep!(Time.seconds(30))?
		Ok({})
	})?
	(tx, rx) = Channel.new!(1)?
	receiver = Task.spawn!(|| {
		value = rx.receive!()?
		Ok(value)
	})?
	Time.sleep!(Time.millis(20))?
	start = Time.now!()
	sleeper.cancel!()
	receiver.cancel!()
	_ = sleeper.join!()
	received = receiver.join!()
	took = start.elapsed!().to_millis()
	tx.close!()
	expect_eq(received, Err(Cancelled))?
	if took < 1000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

task_cancel_finished! = || {
	handle = Task.spawn!(|| Ok("done"))?
	_ = handle.join!()
	handle.cancel!()
	handle.cancel!()
	expect_eq(handle.join!(), Ok("done"))
}

scope_waits! = || {
	(tx, rx) = Channel.new!(10)?
	Task.scope!(|scope| {
		for n in U64.until(0, 3) {
			_ = scope.spawn!(|| {
				Time.sleep!(Time.millis(30))?
				tx.send!(n)
			})?
		}
		Ok({})
	})?
	# Every task finished before scope! returned.
	var $count = 0.U64
	while True {
		match rx.try_receive!() {
			Ok(_) => {
				$count = $count + 1
			}
			Err(_) => break
		}
	}
	expect_eq($count, 3)
}

scope_cancels_on_error! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		Time.sleep!(Time.seconds(30))?
		stream.close!()
		Ok({})
	})?
	start = Time.now!()
	result = Task.scope!(|scope| {
		# Blocked reading a connection that never sends.
		_ = scope.spawn!(|| {
			client = Tcp.connect!(address)?
			_ = client.read!(100)?
			Ok({})
		})?
		failing = scope.spawn!(|| {
			Time.sleep!(Time.millis(20))?
			fail_unless_empty("nope")
		})?
		failing.join!()
	})
	took = start.elapsed!().to_millis()
	expect_eq(result, Err(Boom("nope")))?
	if took < 2000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

scope_nested! = || {
	total = Task.scope!(|outer| {
		a = outer.spawn!(|| {
			Task.scope!(|inner| {
				x = inner.spawn!(|| Ok(1.U64))?
				y = inner.spawn!(|| Ok(2.U64))?
				Ok(x.join!()? + y.join!()?)
			})
		})?
		b = outer.spawn!(|| Ok(10.U64))?
		Ok(a.join!()? + b.join!()?)
	})?
	expect_eq(total, 13)
}

task_is_cancelled! = || {
	handle = Task.spawn!(|| {
		var $spins = 0.U64
		while !Task.is_cancelled!({}) {
			$spins = $spins + 1
			Task.yield!({})
		}
		Ok($spins)
	})?
	Time.sleep!(Time.millis(20))?
	handle.cancel!()
	match handle.join!() {
		Ok(spins) if spins > 0 => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# The first line arrives in two pieces, with the second line right behind
# it; the second select finds that one already buffered.
select_lines! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.set_nodelay!(True)?
		stream.write_str!("hel")?
		Time.sleep!(Time.millis(30))?
		stream.write_str!("lo\nworld\n")?
		Time.sleep!(Time.seconds(2))?
		Ok({})
	})?
	reader = Framing.reader(Tcp.connect!(address)?)
	next_line! = |r| Select.new({})
		.on_line(r, |result| Line(result))
		.on_timeout(Time.seconds(1), || Idle)
		.wait!()
	(first, r1) =
		match next_line!(reader)? {
			Line(Ok((line, next))) => (line, next)
			other => return Err(Unexpected(Str.inspect(other)))
		}
	second =
		match next_line!(r1)? {
			Line(Ok((line, _))) => line
			other => return Err(Unexpected(Str.inspect(other)))
		}
	expect_eq((first, second), ("hello", "world"))
}

select_frames! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		Framing.write_frame!(stream, [1, 2, 3])
	})?
	reader = Framing.reader(Tcp.connect!(address)?)
	got = Select.new({})
		.on_frame(reader, |result| Frame(result))
		.on_timeout(Time.seconds(2), || Idle)
		.wait!()?
	match got {
		Frame(Ok((bytes, _))) => expect_eq(bytes, [1, 2, 3])
		other => Err(Unexpected(Str.inspect(other)))
	}
}

task_cancel_sleep_loop! = || {
	handle = Task.spawn!(|| {
		while True {
			Time.sleep!(Time.millis(5))?
		}
		Ok({})
	})?
	Time.sleep!(Time.millis(30))?
	start = Time.now!()
	handle.cancel!()
	result = handle.join!()
	took = start.elapsed!().to_millis()
	expect_eq(result, Err(Cancelled))?
	if took < 1000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

# Two receivers wait; the first is cancelled and a value sent at once, before
# the cancelled one has run to take itself off the waiting list. The value
# must reach the other receiver.
channel_cancelled_waiter! = || {
	(tx, rx) = Channel.new!(1)?
	(report_tx, report) = Channel.new!(2)?
	first = Task.spawn!(|| {
		value = rx.receive!()?
		report_tx.send!(First(value))
	})?
	Time.sleep!(Time.millis(20))?
	_ = Task.spawn!(|| {
		value = rx.receive!()?
		report_tx.send!(Second(value))
	})?
	Time.sleep!(Time.millis(20))?
	first.cancel!()
	tx.send!("hello")?
	reported = report.receive_timeout!(Time.seconds(2))
	# Still open until now: closing the channel would wake every receiver
	# and hide a lost notification.
	tx.close!()
	expect_eq(reported, Ok(Second("hello")))
}

# A client that connects to a TLS listener but never starts the handshake:
# the server's select must still see its timeout.
select_tls_silent_peer! = || {
	(listener, address) = tls_listen_anywhere!()?
	silent = Tcp.connect!(address)?
	stream = listener.accept!()?
	start = Time.now!()
	got = Select.new({})
		.on_read(stream, 100, |result| Read(result))
		.on_timeout(Time.millis(100), || Idle)
		.wait!()?
	took = start.elapsed!().to_millis()
	silent.close!()
	expect_eq(got, Idle)?
	if took < 1000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

select_tls_server_handshake! = || {
	(listener, address) = tls_listen_anywhere!()?
	_ = Task.spawn!(|| {
		client = Tls.connect_with!(address, trusting_test_ca)?
		client.write_str!("hi")?
		Time.sleep!(Time.seconds(2))?
		Ok({})
	})?
	stream = listener.accept!()?
	got = Select.new({})
		.on_read(stream, 100, |result| Read(result))
		.on_timeout(Time.seconds(3), || Idle)
		.wait!()?
	expect_eq(got, Read(Ok(Str.to_utf8("hi"))))
}

# A client that never starts the handshake, and a Select with no timeout of
# its own: the listener's handshake deadline still ends the wait.
select_tls_handshake_deadline! = || {
	listener = Tls.listen!("127.0.0.1:0", test_server_cert.with_handshake_timeout(Millis(200)))?
	address = listener.local_addr!()?
	silent = Tcp.connect!(address)?
	stream = listener.accept!()?
	start = Time.now!()
	got = Select.new({})
		.on_read(stream, 100, |result| Read(result))
		.wait!()?
	took = start.elapsed!().to_millis()
	silent.close!()
	match got {
		Read(Err(TlsErr(TimedOut))) => {}
		other => return Err(Unexpected(Str.inspect(other)))
	}
	if took >= 150 and took < 2000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

# A read timeout on the stream bounds a Select's wait for it, as it bounds a
# blocking read.
select_read_timeout! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		Time.sleep!(Time.seconds(2))?
		stream.close!()
		Ok({})
	})?
	client = Tcp.connect!(address)?
	client.set_read_timeout!(Millis(100))?
	start = Time.now!()
	got = Select.new({})
		.on_read(client, 100, |result| Read(result))
		.wait!()?
	took = start.elapsed!().to_millis()
	match got {
		Read(Err(TcpErr(TimedOut))) => {}
		other => return Err(Unexpected(Str.inspect(other)))
	}
	if took >= 90 and took < 1000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

# Two tasks select on the same silent stream, which has a 100 ms read
# timeout, the second starting 50 ms after the first: each times out on its
# own schedule.
select_timeouts_per_select! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		Time.sleep!(Time.seconds(2))?
		stream.close!()
		Ok({})
	})?
	client = Tcp.connect!(address)?
	client.set_read_timeout!(Millis(100))?
	wait_for_timeout! = || {
		start = Time.now!()
		got = Select.new({})
			.on_read(client, 100, |result| result)
			.wait!()?
		took = start.elapsed!().to_millis()
		match got {
			Err(TcpErr(TimedOut)) => Ok(took)
			other => Err(Unexpected(Str.inspect(other)))
		}
	}
	first = Task.spawn!(wait_for_timeout!)?
	Time.sleep!(Time.millis(50))?
	second = Task.spawn!(wait_for_timeout!)?
	first_took = first.join!()?
	second_took = second.join!()?
	if first_took >= 90 and second_took >= 90 and first_took < 1000 and second_took < 1000 {
		Ok({})
	} else {
		Err(Unexpected("took ${first_took.to_str()} and ${second_took.to_str()} ms"))
	}
}

# One task reads 4 bytes with a blocking read (holding the TLS read lock
# while it waits); the server sends 8 in one record. The select on the same
# stream is woken when that reader lets go, and gets the other 4, though
# nothing more arrives on the socket.
select_tls_after_other_reader! = || {
	(listener, address) = tls_listen_anywhere!()?
	(go_tx, go) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		# The server's handshake runs on its first write: do it now, so the
		# client's connect can finish.
		stream.write!([])?
		_ = go.receive!()?
		stream.write_str!("abcdefgh")?
		Time.sleep!(Time.seconds(5))?
		Ok({})
	})?
	client = Tls.connect_with!(address, trusting_test_ca)?
	# The select waits first, then the reader: when the data arrives, the
	# select runs first and finds the read lock held by the waiting reader,
	# which then takes everything off the socket. Only the reader letting go
	# of the lock can wake the select.
	selecting = Task.spawn!(|| {
		start = Time.now!()
		got = Select.new({})
			.on_read(client, 4, |result| Read(result))
			.on_timeout(Time.seconds(3), || Idle)
			.wait!()?
		Ok((got, start.elapsed!().to_millis()))
	})?
	Time.sleep!(Time.millis(20))?
	reader = Task.spawn!(|| client.read!(4))?
	Time.sleep!(Time.millis(20))?
	go_tx.send!({})?
	first =
		match reader.join!() {
			Ok(bytes) => bytes
			Err(err) => return Err(ReaderFailed(Str.inspect(err)))
		}
	(second, took) =
		match selecting.join!() {
			Ok(pair) => pair
			Err(err) => return Err(SelectFailed(Str.inspect(err)))
		}
	# Either may get the first 4 bytes; between them they get all 8, promptly.
	match (first, second) {
		(a, Read(Ok(b))) if List.concat(a, b) == Str.to_utf8("abcdefgh") or List.concat(b, a) == Str.to_utf8("abcdefgh") => {}
		other => return Err(Unexpected(Str.inspect(other)))
	}
	if took < 1000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

# One task's read is stuck in the server's TLS handshake (its client never
# sends a ClientHello); a select on the same stream must neither block the
# thread the handshake runs on nor wait past its own timeout. With one worker
# (see scripts/run_net_tests.sh), blocking would stop the handshake for good.
select_during_handshake! = || {
	listener = Tls.listen!("127.0.0.1:0", test_server_cert.with_handshake_timeout(Millis(1000)))?
	address = listener.local_addr!()?
	silent = Tcp.connect!(address)?
	stream = listener.accept!()?
	reader = Task.spawn!(|| stream.read!(10))?
	Time.sleep!(Time.millis(50))?
	start = Time.now!()
	got = Select.new({})
		.on_read(stream, 10, |result| Read(result))
		.on_timeout(Time.millis(200), || Idle)
		.wait!()?
	took = start.elapsed!().to_millis()
	# The stuck handshake still ends, at its deadline.
	handshake = reader.join!()
	silent.close!()
	expect_eq(got, Idle)?
	match handshake {
		Err(TlsErr(TimedOut)) => {}
		other => return Err(Unexpected(Str.inspect(other)))
	}
	if took < 1000 Ok({}) else Err(Unexpected("took ${took.to_str()} ms"))
}

# A proxy in front of a server that speaks first (SMTP, SSH): on the new TLS
# stream, one task reads the client, which starts (and runs) the handshake,
# while another sends the greeting. The writer must not end up waiting
# behind the reader, which after the handshake waits for the client, which
# waits for the greeting.
tls_server_speaks_first! = || {
	(listener, address) = tls_listen_anywhere!()?
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		reader = Task.spawn!(|| {
			reply = stream.read!(100)?
			report_tx.send!(Str.from_utf8_lossy(reply))
		})?
		Time.sleep!(Time.millis(20))?
		stream.write_str!("220 hello\r\n")?
		reader.join!()
	})?
	client = Tls.connect_with!(address, trusting_test_ca)?
	client.set_read_timeout!(Millis(3000))?
	greeting = client.read!(100)?
	client.write_str!("QUIT\r\n")?
	reply = report.receive_timeout!(Time.seconds(3))
	expect_eq((Str.from_utf8_lossy(greeting), reply), ("220 hello\r\n", Ok("QUIT\r\n")))
}

# The server finishes the handshake before using the stream, and sees the
# client's message afterwards. On a client stream (which shook hands while
# connecting) it returns at once.
tls_explicit_handshake! = || {
	(listener, address) = tls_listen_anywhere!()?
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		shook = stream.handshake!()
		message = stream.read!(100)?
		report_tx.send!((shook, Str.from_utf8_lossy(message)))
	})?
	client = Tls.connect_with!(address, trusting_test_ca)?
	client.handshake!()?
	client.write_str!("after the handshake")?
	match report.receive_timeout!(Time.seconds(3))? {
		(Ok({}), message) => expect_eq(message, "after the handshake")
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# A client that sends something other than TLS: the error comes from
# handshake!, not from a later read or write.
tls_explicit_handshake_fails! = || {
	(listener, address) = tls_listen_anywhere!()?
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		report_tx.send!(stream.handshake!())
	})?
	client = Tcp.connect!(address)?
	client.write_str!("GET / HTTP/1.1\r\n\r\n")?
	match report.receive_timeout!(Time.seconds(3))? {
		Err(TlsErr(_)) => Ok({})
		other => Err(Unexpected("expected a failed handshake, got ${Str.inspect(other)}"))
	}
}

tls_missing_cert! = || {
	config = Tls.server_config({ cert_file: "examples/net_tests/certs/missing.pem", key_file: "examples/net_tests/certs/server-key.pem" })
	match Tls.listen!("127.0.0.1:0", config) {
		Err(TlsErr(Other(message))) if Str.contains(message, "missing.pem") => Ok({})
		other => Err(Unexpected("expected an error naming missing.pem, got ${Str.inspect(other)}"))
	}
}

# The CA's key with the server's certificate.
tls_mismatched_key! = || {
	config = Tls.server_config({ cert_file: "examples/net_tests/certs/server.pem", key_file: "examples/net_tests/certs/ca-key.pem" })
	match Tls.listen!("127.0.0.1:0", config) {
		Err(TlsErr(Other(message))) if Str.contains(message, "server.pem") => Ok({})
		other => Err(Unexpected("expected an error naming server.pem, got ${Str.inspect(other)}"))
	}
}

# The peer closes first; shutting down this side afterwards, as a proxy does
# when it passes the close on, is not an error.
shutdown_after_peer_closed! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.close!()
		Ok({})
	})?
	client = Tcp.connect!(address)?
	_ = read_to_end!(client)?
	client.shutdown!(Write)?
	client.shutdown!(Both)?

	(tls_listener, tls_address) = tls_listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = tls_listener.accept!()?
		stream.handshake!()?
		stream.close!()
		Ok({})
	})?
	tls_client = Tls.connect_with!(tls_address, trusting_test_ca)?
	_ = read_to_end!(tls_client)?
	tls_client.shutdown!(Write)?
	tls_client.shutdown!(Both)
}

# One task fails at once; its sibling still runs to completion, and the
# scope waits for it.
scope_child_fails! = || {
	(done_tx, done) = Channel.new!(1)?
	result = Task.scope!(|scope| {
		failing = scope.spawn!(|| fail_unless_empty("nope"))?
		_ = scope.spawn!(|| {
			Time.sleep!(Time.millis(50))?
			done_tx.send!("sibling finished")
		})?
		# Only observed, not returned: the body succeeds.
		Ok(failing.join!())
	})
	expect_eq((result, done.try_receive!()), (Ok(Err(Boom("nope"))), Ok("sibling finished")))
}

# The pattern from `Task.scope!`'s docs: whichever long-running task ends
# first decides, and the other is cancelled.
scope_first_ends! = || {
	start = Time.now!()
	result = Task.scope!(|scope| {
		slow = scope.spawn!(|| sleep_then_fail!(Time.seconds(30), "slow"))?
		fast = scope.spawn!(|| sleep_then_fail!(Time.millis(20), "fast"))?
		first =
			Select.new({})
				.on_join(slow, |ended| ended)
				.on_join(fast, |ended| ended)
				.wait!()?
		match first {
			Ok({}) => Err(Stopped)
			Err(err) => Err(err)
		}
	})
	took = start.elapsed!().to_millis()
	expect_eq((result, took < 5000), (Err(Boom("fast")), True))
}

sleep_then_fail! = |duration, message| {
	Time.sleep!(duration)?
	fail_unless_empty(message)
}

test_certs_dir = "examples/net_tests/certs"

## The test server certificate by default, api.pem for "api.test" and
## wild.pem for "*.apps.test".
sni_config =
	test_server_cert
		.with_cert_for("api.test", { cert_file: "${test_certs_dir}/api.pem", key_file: "${test_certs_dir}/api-key.pem" })
		.with_cert_for("*.apps.test", { cert_file: "${test_certs_dir}/wild.pem", key_file: "${test_certs_dir}/wild-key.pem" })

## Serve `config` until the test ends: each connection reports its
## `server_name!` and `alpn_protocol!` on the channel returned (or the
## handshake's error).
tls_reporting_server! = |config| {
	listener = Tls.listen!("127.0.0.1:0", config)?
	address = listener.local_addr!()?
	(report_tx, report) = Channel.new!(8)?
	_ = Task.spawn!(|| {
		while True {
			stream = listener.accept!()?
			_ = Task.spawn!(|| {
				reported =
					match stream.server_name!() {
						Ok(requested) => {
							name =
								match requested {
									Name(n) => n
									NoName => "NoName"
								}
							match stream.alpn_protocol!() {
								Ok(protocol) => Ok((name, protocol))
								Err(err) => Err(Str.inspect(err))
							}
						}
						Err(err) => Err(Str.inspect(err))
					}
				# The test may be over, and the channel gone, by now.
				_ = report_tx.send!(reported)
				Ok({})
			})
		}
		Ok({})
	})?
	Ok((address, report))
}

## Connect by IP address, checking the certificate against `name` (and
## asking for it with SNI).
connect_as! = |address, name| Tls.connect_with!(address, trusting_test_ca.with_server_name(name))

# Each client checks the certificate against the name it asked for, so a
# connection only succeeds if the server picked the right certificate.
tls_sni_picks_cert! = || {
	(address, _report) = tls_reporting_server!(sni_config)?
	_ = connect_as!(address, "api.test")?
	_ = connect_as!(address, "API.test")?
	_ = connect_as!(address, "x.apps.test")?
	_ = connect_as!(address, "localhost")?
	# No name: the default certificate, which covers 127.0.0.1.
	_ = Tls.connect_with!(address, trusting_test_ca)?
	# A wildcard covers one label only, so this gets the default certificate,
	# which isn't for this name.
	expect_tls_rejected!(connect_as!(address, "a.b.apps.test"), "not valid for name")
}

tls_sni_server_name! = || {
	(address, report) = tls_reporting_server!(sni_config)?
	_ = connect_as!(address, "x.apps.test")?
	named = report.receive_timeout!(Time.seconds(3))?
	# Reported as certificates are chosen: lower case, no trailing dot.
	_ = connect_as!(address, "API.Test.")?
	normalized = report.receive_timeout!(Time.seconds(3))?
	_ = Tls.connect_with!(address, trusting_test_ca)?
	unnamed = report.receive_timeout!(Time.seconds(3))?
	expect_eq((named, normalized, unnamed), (Ok(("x.apps.test", "")), Ok(("api.test", "")), Ok(("NoName", ""))))
}

tls_sni_bad_name! = || {
	config = test_server_cert.with_cert_for("127.0.0.1", { cert_file: "${test_certs_dir}/server.pem", key_file: "${test_certs_dir}/server-key.pem" })
	match Tls.listen!("127.0.0.1:0", config) {
		Err(TlsErr(Other(message))) if Str.contains(message, "DNS name") => Ok({})
		other => Err(Unexpected("expected a rejected name, got ${Str.inspect(other)}"))
	}
}

alpn_server_config = test_server_cert.with_alpn(["h2", "http/1.1"])

tls_alpn_agrees! = || {
	(address, report) = tls_reporting_server!(alpn_server_config)?
	client = Tls.connect_with!(address, trusting_test_ca.with_alpn(["http/1.1", "h2"]))?
	server_side = report.receive_timeout!(Time.seconds(3))?
	# The server's preference wins.
	expect_eq((client.alpn_protocol!()?, server_side), ("h2", Ok(("NoName", "h2"))))
}

tls_alpn_no_overlap! = || {
	(address, report) = tls_reporting_server!(alpn_server_config)?
	client = Tls.connect_with!(address, trusting_test_ca.with_alpn(["spdy/3"]))
	server_side = report.receive_timeout!(Time.seconds(3))?
	match (client, server_side) {
		(Err(TlsErr(Other(message))), Err(_)) if Str.contains(message, "NoApplicationProtocol") => Ok({})
		other => Err(Unexpected("expected both sides to fail, got ${Str.inspect(other)}"))
	}
}

tls_alpn_client_offers_none! = || {
	(address, report) = tls_reporting_server!(alpn_server_config)?
	client = Tls.connect_with!(address, trusting_test_ca)?
	server_side = report.receive_timeout!(Time.seconds(3))?
	expect_eq((client.alpn_protocol!()?, server_side), ("", Ok(("NoName", ""))))
}

## Accept one client on `listener`, connect it to `backend_address`, and
## copy between them; the channel returned gets what `copy_both!` returned.
## The client's side has a 300 ms read (idle) timeout.
proxy_once! = |listener, backend_address| proxy_once_with!(listener, backend_address, 300)

proxy_once_with! = |listener, backend_address, idle_ms| {
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		client = listener.accept!()?
		_ = client.set_read_timeout!(Millis(idle_ms))
		backend = Tcp.connect!(backend_address)?
		report_tx.send!(Stream.copy_both!(client, backend))
	})?
	Ok(report)
}

# The backend reads until the client has finished sending, then replies:
# the client's half-close must reach it through the proxy, and the reply
# must come back after it.
copy_both_tcp! = || {
	(backend, backend_address) = listen_anywhere!()?
	serve_length!(backend)?
	(front, front_address) = listen_anywhere!()?
	report = proxy_once!(front, backend_address)?
	client = Tcp.connect!(front_address)?
	reply = exchange!(client, "hello through the proxy")?
	match report.receive_timeout!(Time.seconds(3))? {
		Ok(copied) => expect_eq((reply, copied.a_to_b, copied.b_to_a), ("got 23 bytes", 23, 12))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

copy_both_tls_to_tcp! = || {
	(backend, backend_address) = listen_anywhere!()?
	serve_length!(backend)?
	(front, front_address) = tls_listen_anywhere!()?
	report = proxy_once!(front, backend_address)?
	client = Tls.connect_with!(front_address, trusting_test_ca)?
	reply = exchange!(client, "secret")?
	match report.receive_timeout!(Time.seconds(3))? {
		Ok(copied) => expect_eq((reply, copied.a_to_b, copied.b_to_a), ("got 6 bytes", 6, 11))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# The client sends nothing for longer than its 300 ms read timeout while
# the backend streams to it: that's not idle.
copy_both_one_way! = || {
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = backend.accept!()?
		var $i = 0
		while $i < 8 {
			stream.write_str!("tick")?
			Time.sleep!(Time.millis(100))?
			$i = $i + 1
		}
		Ok({})
	})?
	(front, front_address) = listen_anywhere!()?
	report = proxy_once!(front, backend_address)?
	client = Tcp.connect!(front_address)?
	received = read_to_end!(client)?
	client.close!()
	match report.receive_timeout!(Time.seconds(3))? {
		Ok(copied) => expect_eq((Str.count_utf8_bytes(received), copied.b_to_a), (32, 32))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# Neither side sends: the client's read timeout ends the session.
copy_both_idle! = || {
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = backend.accept!()?
		_ = read_to_end!(stream)
		Ok({})
	})?
	(front, front_address) = listen_anywhere!()?
	report = proxy_once!(front, backend_address)?
	client = Tcp.connect!(front_address)?
	reported = report.receive_timeout!(Time.seconds(3))?
	# Keep the client open until then.
	client.close!()
	match reported {
		Err(CopyErr({ failed: ReadA(TimedOut), a_to_b: 0, b_to_a: 0 })) => Ok({})
		other => Err(Unexpected("expected ReadA(TimedOut), got ${Str.inspect(other)}"))
	}
}

# Cancelling the proxying task ends both directions and aborts both
# streams: the client sees a reset, not a clean end.
copy_both_cancelled! = || {
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = backend.accept!()?
		_ = read_to_end!(stream)
		Ok({})
	})?
	(front, front_address) = listen_anywhere!()?
	proxy = Task.spawn!(|| {
		client = front.accept!()?
		backend_stream = Tcp.connect!(backend_address)?
		Stream.copy_both!(client, backend_stream)
	})?
	client = Tcp.connect!(front_address)?
	client.set_read_timeout!(Millis(3000))?
	Time.sleep!(Time.millis(50))?
	proxy.cancel!()
	ended = client.read!(10)
	match (proxy.join!(), ended) {
		(Err(Cancelled), Err(TcpErr(ConnectionReset))) => Ok({})
		other => Err(Unexpected("expected Cancelled and a reset, got ${Str.inspect(other)}"))
	}
}

## Any stream with `read!` and `write!`, as in `Stream`'s docs.
echo_once! : s => Try({}, e)
	where [
		s.read! : s, U64 => Try(List(U8), e),
		s.write! : s, List(U8) => Try({}, e),
	]
echo_once! = |stream| {
	bytes = stream.read!(100)?
	stream.write!(bytes)
}

MixedListener : [Plain(Tcp.Listener), Secure(Tls.Listener)]

serve_mixed! : MixedListener => Try({}, _)
serve_mixed! = |listener|
	match listener {
		Plain(l) => echo_once!(l.accept!()?)
		Secure(l) => echo_once!(l.accept!()?)
	}

stream_generic! = || {
	(plain, plain_address) = listen_anywhere!()?
	(secure, secure_address) = tls_listen_anywhere!()?
	listeners : List(MixedListener)
	listeners = [Plain(plain), Secure(secure)]
	for listener in listeners {
		_ = Task.spawn!(|| serve_mixed!(listener))?
	}
	tcp = Tcp.connect!(plain_address)?
	tcp.write_str!("plain")?
	tls = Tls.connect_with!(secure_address, trusting_test_ca)?
	tls.write_str!("secure")?
	expect_eq((tcp.read!(100)?, tls.read!(100)?), (Str.to_utf8("plain"), Str.to_utf8("secure")))
}

select_join_first! = || {
	slow = Task.spawn!(|| sleep_then_fail!(Time.seconds(30), "slow"))?
	fast = Task.spawn!(|| sleep_then_fail!(Time.millis(20), "fast"))?
	start = Time.now!()
	first =
		Select.new({})
			.on_join(slow, |result| Slow(result))
			.on_join(fast, |result| Fast(result))
			.wait!()?
	took = start.elapsed!().to_millis()
	slow.cancel!()
	expect_eq((first, took < 5000), (Fast(Err(Boom("fast"))), True))
}

select_join_finished! = || {
	done = Task.spawn!(|| Ok(42))?
	_ = done.join!()?
	first =
		Select.new({})
			.on_join(done, |result| result)
			.on_timeout(Time.seconds(5), || Err(Boom("timed out")))
			.wait!()?
	expect_eq(first, Ok(42))
}

# A timeout while the task runs; then the task finishes, and its result is
# still there for the next wait (joining doesn't consume it).
select_join_timeout! = || {
	task = Task.spawn!(|| {
		Time.sleep!(Time.millis(100))?
		Ok("finished")
	})?
	early =
		Select.new({})
			.on_join(task, |result| Joined(result))
			.on_timeout(Time.millis(10), || Waiting)
			.wait!()?
	later =
		Select.new({})
			.on_join(task, |result| Joined(result))
			.on_timeout(Time.seconds(5), || Waiting)
			.wait!()?
	expect_eq((early, later, task.join!()), (Waiting, Joined(Ok("finished")), Ok("finished")))
}

## A backend that sends `size` bytes of a longer response, then gives up.
backend_resetting_after! = |size| {
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = backend.accept!()?
		stream.write!(List.repeat(120, size))?
		Time.sleep!(Time.millis(50))?
		stream.abort!()
		Ok({})
	})?
	Ok(backend_address)
}

## Read until the end of the stream or an error; the bytes and how it ended.
read_until_end_or_error! = |stream| {
	var $count = 0
	while True {
		match stream.read!(65536) {
			Ok([]) => return (Ok({}), $count)
			Ok(bytes) => {
				$count = $count + List.len(bytes)
			}
			Err(err) => return (Err(err), $count)
		}
	}
	(Ok({}), $count)
}

# The must-not-happen case for a TLS terminator: a truncated response
# followed by close_notify, which the client would take as complete.
copy_both_reset_tls! = || {
	backend_address = backend_resetting_after!(200000)?
	(front, front_address) = tls_listen_anywhere!()?
	report = proxy_once!(front, backend_address)?
	client = Tls.connect_with!(front_address, trusting_test_ca)?
	client.set_read_timeout!(Millis(3000))?
	(ended, received) = read_until_end_or_error!(client)
	reported = report.receive_timeout!(Time.seconds(3))?
	match (ended, reported) {
		(Err(TlsErr(_)), Err(CopyErr({ failed: ReadB(ConnectionReset), b_to_a, .. }))) =>
			expect_eq((received <= 200000, b_to_a <= 200000), (True, True))
		other => Err(Unexpected("expected an error at the client, got ${Str.inspect(other)}"))
	}
}

copy_both_reset_tcp! = || {
	backend_address = backend_resetting_after!(200000)?
	(front, front_address) = listen_anywhere!()?
	report = proxy_once!(front, backend_address)?
	client = Tcp.connect!(front_address)?
	client.set_read_timeout!(Millis(3000))?
	(ended, _) = read_until_end_or_error!(client)
	_ = report.receive_timeout!(Time.seconds(3))?
	match ended {
		Err(TcpErr(ConnectionReset)) => Ok({})
		other => Err(Unexpected("expected a reset at the client, got ${Str.inspect(other)}"))
	}
}

# Once data is flowing to the client, the client stops reading (and sends
# nothing) for twice its 800 ms read timeout at the proxy, while the backend
# has 16 MB for it: the proxy's write to the client is stuck, which isn't
# idle, so the session survives. (It waits for data to flow first: before
# any does, a silent session is idle, and a slow machine may take a while
# to start.)
copy_both_slow_reader! = || {
	chunk_size = 64 * 1024
	chunks = 256
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = backend.accept!()?
		chunk = List.repeat(120, chunk_size)
		for _ in U64.until(0, chunks) {
			stream.write!(chunk)?
		}
		stream.shutdown!(Write)?
		_ = read_to_end!(stream)
		Ok({})
	})?
	(front, front_address) = listen_anywhere!()?
	report = proxy_once_with!(front, backend_address, 800)?
	client = Tcp.connect!(front_address)?
	client.set_read_timeout!(Millis(10000))?
	first = client.read!(1)?
	Time.sleep!(Time.millis(1600))?
	(ended, rest) = read_until_end_or_error!(client)
	client.shutdown!(Write)?
	size = chunk_size * chunks
	match (ended, report.receive_timeout!(Time.seconds(10))?) {
		(Ok({}), Ok(copied)) => expect_eq((List.len(first) + rest, copied.b_to_a), (size, size))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

abort_is_not_clean! = || {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		_ = stream.read!(10)?
		stream.write_str!("partial")?
		stream.abort!()
		Ok({})
	})?
	tcp = Tcp.connect!(address)?
	tcp.write_str!("go")?
	tcp.set_read_timeout!(Millis(3000))?
	(tcp_ended, _) = read_until_end_or_error!(tcp)

	(tls_listener, tls_address) = tls_listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = tls_listener.accept!()?
		_ = stream.read!(10)?
		stream.write_str!("partial")?
		stream.abort!()
		# Released after aborting: still no close_notify.
		Ok({})
	})?
	tls = Tls.connect_with!(tls_address, trusting_test_ca)?
	tls.write_str!("go")?
	tls.set_read_timeout!(Millis(3000))?
	(tls_ended, _) = read_until_end_or_error!(tls)
	match (tcp_ended, tls_ended) {
		(Err(TcpErr(ConnectionReset)), Err(TlsErr(_))) => Ok({})
		other => Err(Unexpected("expected errors, got ${Str.inspect(other)}"))
	}
}

# 32 sessions at once, each 50 small round trips: many directions going idle
# and busy again, across worker threads (the stealing pass moves them). This
# is what caught buffers and pipes being reused from another thread's pool.
copy_both_many_sessions! = || {
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		while True {
			stream = backend.accept!()?
			_ = Task.spawn!(|| {
				while True {
					bytes = stream.read!(100)?
					if List.is_empty(bytes) {
						break
					}
					stream.write!(bytes)?
				}
				Ok({})
			})
		}
		Ok({})
	})?
	(front, front_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		while True {
			client = front.accept!()?
			_ = Task.spawn!(|| {
				upstream = Tcp.connect!(backend_address)?
				_ = Stream.copy_both!(client, upstream)
				Ok({})
			})
		}
		Ok({})
	})?
	var $clients = []
	for i in U64.until(0, 32) {
		client = Task.spawn!(|| {
			stream = Tcp.connect!(front_address)?
			stream.set_read_timeout!(Millis(5000))?
			for round in U64.until(0, 50) {
				message = "session ${i.to_str()} round ${round.to_str()}"
				stream.write_str!(message)?
				reply = stream.read!(100)?
				if Str.from_utf8_lossy(reply) != message {
					return Err(Mismatch({ expected: message, actual: Str.from_utf8_lossy(reply) }))
				}
			}
			Ok({})
		})?
		$clients = List.append($clients, client)
	}
	for client in $clients {
		client.join!()?
	}
	Ok({})
}

# Unix sockets: `splice` on Linux (or its fallback), and mixed with TCP.
copy_both_unix! = || {
	backend = Unix.listen!("/tmp/roc-net-tests-copy-backend.sock")?
	serve_length!(backend)?
	front = Unix.listen!("/tmp/roc-net-tests-copy-front.sock")?
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		client = front.accept!()?
		upstream = Unix.connect!("/tmp/roc-net-tests-copy-backend.sock")?
		report_tx.send!(Stream.copy_both!(client, upstream))
	})?
	client = Unix.connect!("/tmp/roc-net-tests-copy-front.sock")?
	reply = exchange!(client, "over unix sockets")?
	unix_copied =
		match report.receive_timeout!(Time.seconds(3))? {
			Ok(copied) => (copied.a_to_b, copied.b_to_a)
			other => return Err(Unexpected(Str.inspect(other)))
		}

	(tcp_backend, tcp_backend_address) = listen_anywhere!()?
	serve_length!(tcp_backend)?
	mixed_front = Unix.listen!("/tmp/roc-net-tests-copy-mixed.sock")?
	(mixed_tx, mixed_report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		mixed_client = mixed_front.accept!()?
		upstream = Tcp.connect!(tcp_backend_address)?
		mixed_tx.send!(Stream.copy_both!(mixed_client, upstream))
	})?
	mixed = Unix.connect!("/tmp/roc-net-tests-copy-mixed.sock")?
	mixed_reply = exchange!(mixed, "unix to tcp")?
	match mixed_report.receive_timeout!(Time.seconds(3))? {
		Ok(copied) =>
			expect_eq(
				(reply, unix_copied, mixed_reply, copied.a_to_b, copied.b_to_a),
				("got 17 bytes", (17, 12), "got 11 bytes", 11, 12),
			)
		other => Err(Unexpected(Str.inspect(other)))
	}
}
