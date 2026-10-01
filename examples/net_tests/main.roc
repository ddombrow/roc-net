app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Bytes
import pf.Channel
import pf.Cryptography as C
import pf.Dns
import pf.Env
import pf.File
import pf.Framing
import pf.Log
import pf.Noise
import pf.Random
import pf.Select
import pf.Stdout
import pf.Pipe
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
		check!("copy_both!: a timeout after a complete response doesn't reset the client", copy_both_timeout_after_complete_response!),
		check!("copy_both!: data that arrived before it started is copied", copy_both_data_waiting!),
		check!("copy_to!: two small messages buffered together, the second left in the reader", copy_to_pipelined_small!),
		check!("copy_to!: pipelined messages over tcp, the next one left intact", copy_to_pipelined_tcp!),
		check!("copy_to!: pipelined messages over tls, the next one left intact", copy_to_pipelined_tls!),
		check!("copy_to!: a limit inside one tls record leaves the rest readable", copy_to_within_tls_record!),
		check!("copy_to!: Exactly(0) copies nothing", copy_to_zero!),
		check!("copy_to!: the source ending early is UnexpectedEof, with the count", copy_to_ends_early!),
		check!("copy_to!: UntilEnd, and neither stream is shut down", copy_to_until_end!),
		check!("copy_to!: tls to tls", copy_to_tls_to_tls!),
		check!("copy_to!: cancelling returns Cancelled", copy_to_cancelled!),
		check!("reader.copy_to!: Exactly(n) is one message, under the message timeout", copy_to_message_timeout!),
		check!("reader.copy_to!: UntilEnd isn't a message, so no message timeout", copy_to_until_end_no_message_timeout!),
		check!("time: Utc as RFC 3339, around the epoch, a leap day, the range's edges", time_utc_rfc3339!),
		check!("time: Utc conversions round towards the past", time_utc_conversions!),
		check!("time: utc_now! is the wall clock", time_utc_now!),
		check!("log: many tasks logging at once, and the default level", log_many_tasks!),
		check!("crypto: HMAC-SHA-256, RFC 4231", crypto_hmac!),
		check!("crypto: HKDF-SHA-256, RFC 5869", crypto_hkdf!),
		check!("crypto: X25519, RFC 7748, and a low-order point", crypto_x25519!),
		check!("crypto: ChaCha20-Poly1305, RFC 8439, and tampering", crypto_chachapoly!),
		check!("crypto: AES-256-GCM, the GCM spec's test cases", crypto_aesgcm!),
		check!("crypto: Ed25519, RFC 8032", crypto_ed25519!),
		check!("crypto: generated keys, wrong lengths, constant-time compare", crypto_misc!),
		check!("noise: XX over tcp, with payloads, keys, and Framing on top", noise_xx_tcp!),
		check!("noise: a write larger than a message is split and rejoined", noise_large_write!),
		check!("noise: the wrong static key, or a different psk, fails the handshake", noise_wrong_keys!),
		check!("noise: a flipped byte in transit fails to authenticate", noise_tampered!),
		check!("noise: over a unix socket", noise_unix!),
		check!("bytes: hex both ways, and its errors", bytes_hex!),
		check!("random: bytes! gives up to 16 MiB, and refuses more", random_bytes_limit!),
		check!("noise: CipherState.with_nonce decrypts out of order", noise_with_nonce!),
		check!("scope: cancel_all! stops a helper the body no longer needs", scope_cancel_all!),
		check!("noise: Select waits for a whole message, kept across waits", noise_select_partial!),
		check!("noise: one task selects on a Noise reader and a channel", noise_select_with_channel!),
		check!("noise: Pipe.copy_both! between a Noise and a plain stream", noise_pipe!),
		check!("noise: after a message fails to authenticate, reads keep failing", noise_stays_failed!),
		check!("noise: two Select readers share a stream; every byte arrives", noise_shared_readers!),
		check!("tls: two Select readers share a stream; every byte arrives", tls_shared_readers!),
		check!("file: write, read, append, replace, delete", file_round_trip!),
		check!("file: write_new! refuses an existing file", file_write_new!),
		check!("file: write_atomic! replaces, and creates", file_write_atomic!),
		check!("file: rename! moves, replacing the target", file_rename!),
		check!("file: errors (missing, a directory, bad UTF-8)", file_errors!),
		check!("file: 20 tasks at once, each with its own file", file_many_tasks!),
		check!("env: var! finds, misses, and rejects impossible names", env_var!),
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
	a = Random.bytes!(16)?
	b = Random.bytes!(16)?
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
		report_tx.send!(Pipe.copy_both!(client, backend))
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
		Pipe.copy_both!(client, backend_stream)
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

## Any stream with `read!` and `write!`, as in `Pipe`'s docs.
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
# nothing) for twice its 1 s read timeout at the proxy, while the backend has
# 16 MB for it. Where the sockets' buffers can't hold it all, the proxy's
# write to the client is stuck, which isn't idle, so the session survives.
# Where they can (large Linux autotuning), the backend's side finishes, and
# the proxy then times out waiting for the client, which is fair; either
# way the client gets all 16 MB and a clean end. Without the rule, the first
# case resets the client mid-transfer.
copy_both_slow_reader! = || {
	chunk_size = 64 * 1024
	chunks = 256
	size = chunk_size * chunks
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
	report = proxy_once_with!(front, backend_address, 1000)?
	client = Tcp.connect!(front_address)?
	client.set_read_timeout!(Millis(10000))?
	# On a failure, say what the proxy reported: the client only sees a reset.
	proxy_said! = || Str.inspect(report.receive_timeout!(Time.seconds(10)))
	first =
		match client.read!(1) {
			Ok(bytes) => bytes
			Err(err) => return Err(Unexpected("first read: ${Str.inspect(err)}; proxy: ${proxy_said!()}"))
		}
	Time.sleep!(Time.millis(2000))?
	(ended, rest) = read_until_end_or_error!(client)
	received = List.len(first) + rest
	_ = client.shutdown!(Write)
	match ended {
		Ok({}) =>
			match report.receive_timeout!(Time.seconds(10))? {
				Ok(copied) => expect_eq((received, copied.b_to_a), (size, size))
				Err(CopyErr({ failed: ReadA(TimedOut), b_to_a, .. })) => expect_eq((received, b_to_a), (size, size))
				other => Err(Unexpected(Str.inspect(other)))
			}
		Err(err) => Err(Unexpected("after ${received.to_str()} bytes: ${Str.inspect(err)}; proxy: ${proxy_said!()}"))
	}
}

# The backend sends a whole response and closes; the client, slow, reads
# it only after its idle timeout at the proxy has passed. The proxy gives
# up waiting for the client, but the response was complete, so the client
# still gets all of it with a clean end: no reset to throw away what it
# hadn't read.
copy_both_timeout_after_complete_response! = || {
	size = 100000
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = backend.accept!()?
		stream.write!(List.repeat(120, size))?
		stream.shutdown!(Write)?
		_ = read_to_end!(stream)
		Ok({})
	})?
	(front, front_address) = listen_anywhere!()?
	report = proxy_once!(front, backend_address)?
	client = Tcp.connect!(front_address)?
	reported = report.receive_timeout!(Time.seconds(10))?
	(ended, received) = read_until_end_or_error!(client)
	match (ended, reported) {
		(Ok({}), Err(CopyErr({ failed: ReadA(TimedOut), b_to_a, a_to_b: 0 }))) =>
			expect_eq((received, b_to_a), (size, size))
		other => Err(Unexpected("after ${received.to_str()} bytes: ${Str.inspect(other)}"))
	}
}

# Each server waits for the client to speak before aborting: a reset that
# arrives before the client's connect has finished fails the connect itself
# (as it should; Linux is quick enough to do that on loopback).
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
				_ = Pipe.copy_both!(client, upstream)
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
		report_tx.send!(Pipe.copy_both!(client, upstream))
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
		mixed_tx.send!(Pipe.copy_both!(mixed_client, upstream))
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

# The backend sends a greeting before `copy_both!` starts, then nothing
# more, and the proxy sleeps first, so the event loop reports that data
# while no one is waiting for it and drops the event. The copy must still
# find it: readiness events are edge-triggered, and waiting before checking
# would wait for more data that never comes. (In CI, on one worker thread,
# the backend filled every buffer before the copy began, and the session
# timed out with nothing copied.)
copy_both_data_waiting! = || {
	(backend, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = backend.accept!()?
		stream.write_str!("hello from the backend")?
		_ = read_to_end!(stream)
		Ok({})
	})?
	(front, front_address) = listen_anywhere!()?
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		client = front.accept!()?
		_ = client.set_read_timeout!(Millis(1000))
		upstream = Tcp.connect!(backend_address)?
		Time.sleep!(Time.millis(100))?
		# Best effort: only read when the test fails.
		_ = report_tx.send!(Pipe.copy_both!(client, upstream))
		Ok({})
	})?
	client = Tcp.connect!(front_address)?
	client.set_read_timeout!(Millis(5000))?
	greeting = client.read!(100)
	client.close!()
	match greeting {
		Ok(bytes) => expect_eq(Str.from_utf8_lossy(bytes), "hello from the backend")
		other => Err(Unexpected("${Str.inspect(other)}; proxy: ${Str.inspect(report.receive_timeout!(Time.seconds(5)))}"))
	}
}

## A listener that accepts one connection, reads it to the end, and sends
## what it got on the channel returned.
collector! = || {
	(listener, address) = listen_anywhere!()?
	(got_tx, got) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		bytes = read_to_end!(stream)?
		_ = got_tx.send!(bytes)
		Ok({})
	})?
	Ok((address, got))
}

## Two messages, each a line with its length and then that many bytes, sent
## in one write: a 200 KB body (partly buffered by the reader's first read,
## the rest copied from the stream, with `splice` on Linux), then "abc".
two_messages = {
	body = Str.from_utf8_lossy(List.repeat(120, 200000))
	"200000\n${body}3\nabc"
}

## Read the two messages from `reader`, copying each body to its own
## connection to `sink_address`; the bodies the sink got, in order.
copy_two_bodies! = |reader, sink_address| {
	(first_line, r1) = reader.read_line!()?
	first_len = U64.from_str(first_line)?
	sink1 = Tcp.connect!(sink_address)?
	(copied1, r2) = r1.copy_to!(sink1, Exactly(first_len))?
	sink1.shutdown!(Write)?
	(second_line, r3) = r2.read_line!()?
	second_len = U64.from_str(second_line)?
	(second, _) = r3.read_exactly!(second_len)?
	Ok((copied1, Str.from_utf8_lossy(second)))
}

copy_to_pipelined_tcp! = || {
	(sink_address, got) = collector!()?
	(listener, address) = listen_anywhere!()?
	(result_tx, result) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		_ = result_tx.send!(copy_two_bodies!(Framing.reader(stream), sink_address))
		Ok({})
	})?
	client = Tcp.connect!(address)?
	client.write_str!(two_messages)?
	match result.receive_timeout!(Time.seconds(10))? {
		Ok((copied, second)) =>
			expect_eq((copied, second, Str.count_utf8_bytes(got.receive_timeout!(Time.seconds(10))?)), (200000, "abc", 200000))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

copy_to_pipelined_tls! = || {
	(sink_address, got) = collector!()?
	(listener, address) = tls_listen_anywhere!()?
	(result_tx, result) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		_ = result_tx.send!(copy_two_bodies!(Framing.reader(stream), sink_address))
		Ok({})
	})?
	# Keep the client open until the result is in: closing it with unread
	# data (the server's TLS session tickets) makes Linux reset the
	# connection under the server's reads.
	client = Tls.connect_with!(address, trusting_test_ca)?
	client.write_str!(two_messages)?
	outcome = result.receive_timeout!(Time.seconds(10))?
	client.close!()
	match outcome {
		Ok((copied, second)) =>
			expect_eq((copied, second, Str.count_utf8_bytes(got.receive_timeout!(Time.seconds(10))?)), (200000, "abc", 200000))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# One 1,000-byte write is one TLS record; copying 100 of it must leave the
# other 900 for the stream's next read.
copy_to_within_tls_record! = || {
	(sink_address, got) = collector!()?
	(listener, address) = tls_listen_anywhere!()?
	(result_tx, result) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		sink = Tcp.connect!(sink_address)?
		copied = Pipe.copy_to!(stream, sink, Exactly(100))
		sink.close!()
		rest = read_to_end!(stream)
		_ = result_tx.send!((copied, rest))
		Ok({})
	})?
	client = Tls.connect_with!(address, trusting_test_ca)?
	client.write!(List.concat(List.repeat(97, 100), List.repeat(98, 900)))?
	# Ending the session (close_notify) is how the server's read learns the
	# rest is complete; shutting down only writing keeps unread data from
	# turning the close into a reset on Linux.
	client.shutdown!(Write)?
	outcome = result.receive_timeout!(Time.seconds(10))?
	client.close!()
	match outcome {
		(Ok(copied), Ok(rest)) =>
			expect_eq((copied, got.receive_timeout!(Time.seconds(10))?, rest), (100, Str.from_utf8_lossy(List.repeat(97, 100)), Str.from_utf8_lossy(List.repeat(98, 900))))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

copy_to_zero! = || {
	(sink_address, got) = collector!()?
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.write_str!("untouched")?
		Ok({})
	})?
	source = Tcp.connect!(address)?
	sink = Tcp.connect!(sink_address)?
	copied = Pipe.copy_to!(source, sink, Exactly(0))?
	sink.close!()
	rest = read_to_end!(source)?
	expect_eq((copied, got.receive_timeout!(Time.seconds(10))?, rest), (0, "", "untouched"))
}

copy_to_ends_early! = || {
	(sink_address, got) = collector!()?
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.write_str!("only this")?
		stream.shutdown!(Write)?
		_ = read_to_end!(stream)
		Ok({})
	})?
	source = Tcp.connect!(address)?
	sink = Tcp.connect!(sink_address)?
	result = Pipe.copy_to!(source, sink, Exactly(1000))
	sink.close!()
	match result {
		Err(CopyToErr({ failed: Read(UnexpectedEof), copied })) =>
			expect_eq((copied, got.receive_timeout!(Time.seconds(10))?), (9, "only this"))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# After copying to the end of the source, the sink is still open: more can
# be written to it, and it ends only when told to.
copy_to_until_end! = || {
	(sink_address, got) = collector!()?
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.write_str!("from the source; ")?
		stream.shutdown!(Write)?
		_ = read_to_end!(stream)
		Ok({})
	})?
	source = Tcp.connect!(address)?
	sink = Tcp.connect!(sink_address)?
	copied = Pipe.copy_to!(source, sink, UntilEnd)?
	sink.write_str!("then more")?
	sink.shutdown!(Write)?
	expect_eq((copied, got.receive_timeout!(Time.seconds(10))?), (17, "from the source; then more"))
}

copy_to_tls_to_tls! = || {
	(tls_sink, tls_sink_address) = tls_listen_anywhere!()?
	(got_tx, got) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = tls_sink.accept!()?
		bytes = read_to_end!(stream)?
		_ = got_tx.send!(bytes)
		Ok({})
	})?
	(listener, address) = tls_listen_anywhere!()?
	(result_tx, result) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		sink = Tls.connect_with!(tls_sink_address, trusting_test_ca)?
		copied = Pipe.copy_to!(stream, sink, Exactly(50000))
		sink.shutdown!(Write)?
		_ = result_tx.send!(copied)
		Ok({})
	})?
	# Keep the client open until the result is in: closing it with unread
	# data (the server's TLS session tickets) makes Linux reset the
	# connection under the server's reads.
	client = Tls.connect_with!(address, trusting_test_ca)?
	client.write!(List.repeat(122, 50000))?
	outcome = result.receive_timeout!(Time.seconds(10))?
	client.close!()
	match outcome {
		Ok(copied) => expect_eq((copied, Str.count_utf8_bytes(got.receive_timeout!(Time.seconds(10))?)), (50000, 50000))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

copy_to_cancelled! = || {
	(sink_address, _got) = collector!()?
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		stream.write_str!("a little, then nothing")?
		Time.sleep!(Time.seconds(30))?
		# Still open until here (unused, it would close at once).
		stream.close!()
		Ok({})
	})?
	copier = Task.spawn!(|| {
		source = Tcp.connect!(address)?
		sink = Tcp.connect!(sink_address)?
		Pipe.copy_to!(source, sink, Exactly(1000))
	})?
	Time.sleep!(Time.millis(100))?
	copier.cancel!()
	match copier.join!() {
		Err(Cancelled) => Ok({})
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# Both messages fit in the reader's first read, so the buffer holds the
# whole first body and all of the second message: copying the first must
# take only its 5 bytes, leaving the rest in the reader returned.
copy_to_pipelined_small! = || {
	(sink_address, got) = collector!()?
	(listener, address) = listen_anywhere!()?
	(result_tx, result) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		_ = result_tx.send!(copy_two_bodies!(Framing.reader(stream), sink_address))
		Ok({})
	})?
	client = Tcp.connect!(address)?
	client.write_str!("5\nhello3\nabc")?
	match result.receive_timeout!(Time.seconds(10))? {
		Ok((copied, second)) => expect_eq((copied, second, got.receive_timeout!(Time.seconds(10))?), (5, "abc", "hello"))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

## A peer that sends `count` bytes one at a time, `gap_ms` apart (well within
## any idle timeout), then closes.
trickler! = |count, gap_ms| {
	(listener, address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		for _ in U64.until(0, count) {
			# Stop once the other end gives up (as the timeout test's does).
			match stream.write_str!("x") {
				Ok({}) => {}
				Err(_) => return Ok({})
			}
			Time.sleep!(Time.millis(gap_ms))?
		}
		stream.close!()
		Ok({})
	})?
	Ok(address)
}

# A body trickled a byte every 50 ms can't hold the copy past the reader's
# 400 ms message timeout, though no single read ever waits long.
copy_to_message_timeout! = || {
	address = trickler!(100, 50)?
	(sink_address, _got) = collector!()?
	source = Tcp.connect!(address)?
	sink = Tcp.connect!(sink_address)?
	reader = Framing.reader(source).with_message_timeout(Millis(400))
	start = Time.now!()
	result = reader.copy_to!(sink, Exactly(100))
	took = start.elapsed!().to_millis()
	sink.close!()
	match result {
		Err(CopyToErr({ failed: MessageTimedOut, copied })) =>
			expect_eq((copied < 100, took >= 350, took < 2000), (True, True, True))
		other => Err(Unexpected(Str.inspect(other)))
	}
}

# The same trickle, for longer than the message timeout, copied `UntilEnd`:
# a stream, so only the stream's read timeout applies, and it all arrives.
copy_to_until_end_no_message_timeout! = || {
	address = trickler!(12, 50)?
	(sink_address, got) = collector!()?
	source = Tcp.connect!(address)?
	sink = Tcp.connect!(sink_address)?
	reader = Framing.reader(source).with_message_timeout(Millis(200))
	(copied, _) = reader.copy_to!(sink, UntilEnd)?
	sink.close!()
	expect_eq((copied, got.receive_timeout!(Time.seconds(10))?), (12, "xxxxxxxxxxxx"))
}

# The edges of the range are an I64 of nanoseconds; past them, conversions
# from milliseconds or seconds saturate there.
time_utc_rfc3339! = || {
	formatted = List.map([0, 951782400000, -1, -86400001, 1759235696789], |ms| Time.utc_from_millis(ms).to_rfc3339())
	edges = [Time.utc_from_nanos(I64.highest).to_rfc3339(), Time.utc_from_nanos(I64.lowest).to_rfc3339(), Time.utc_from_millis(I64.highest).to_rfc3339()]
	expect_eq(
		(formatted, edges),
		(
			["1970-01-01T00:00:00.000Z", "2000-02-29T00:00:00.000Z", "1969-12-31T23:59:59.999Z", "1969-12-30T23:59:59.999Z", "2025-09-30T12:34:56.789Z"],
			["2262-04-11T23:47:16.854Z", "1677-09-21T00:12:43.145Z", "2262-04-11T23:47:16.854Z"],
		),
	)
}

time_utc_conversions! = || {
	before = Time.utc_from_nanos(-1)
	after = Time.utc_from_nanos(1999999999)
	expect_eq(
		(before.to_millis_since_epoch(), before.to_seconds_since_epoch(), after.to_millis_since_epoch(), after.to_seconds_since_epoch(), Time.utc_from_seconds(2).to_nanos_since_epoch()),
		(-1, -1, 1999, 1, 2000000000),
	)
}

# After this code was written, and before it's likely to still run.
time_utc_now! = || {
	now = Time.utc_now!()
	later = Time.utc_now!()
	seconds = now.to_seconds_since_epoch()
	expect_eq((seconds > 1790000000, seconds < 4102444800, later.is_lt(now)), (True, True, False))
}

# Logging from many tasks at once only queues lines, so it's quick; whether
# the lines come out whole is scripts/run_log_tests.sh's to check.
log_many_tasks! = || {
	start = Time.now!()
	var $tasks = []
	for i in U64.until(0, 50) {
		task = Task.spawn!(|| {
			for n in U64.until(0, 20) {
				Log.debug!("not written at the default level", [U64("task", i), U64("n", n)])
			}
			Ok({})
		})?
		$tasks = List.append($tasks, task)
	}
	for task in $tasks {
		task.join!()?
	}
	expect_eq((Log.enabled!(Debug), Log.enabled!(Info), start.elapsed!().to_millis() < 5000), (False, True, True))
}

## Bytes from hex (test vectors), ignoring the spaces they're grouped with.
hex = |text| Bytes.from_hex(Str.from_utf8_lossy(List.keep_if(Str.to_utf8(text), |c| c != 32))) ?? []

crypto_hmac! = || {
	case1 = C.HmacSha256.tag(List.repeat(0x0b, 20), Str.to_utf8("Hi There"))
	case2 = C.HmacSha256.tag(Str.to_utf8("Jefe"), Str.to_utf8("what do ya want for nothing?"))
	# A key longer than the 64-byte block is hashed first.
	case6 = C.HmacSha256.tag(List.repeat(0xaa, 131), Str.to_utf8("Test Using Larger Than Block-Size Key - Hash Key First"))
	expect_eq(
		(case1, case2, case6),
		(
			hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
			hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
			hex("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
		),
	)
}

crypto_hkdf! = || {
	ikm = List.repeat(0x0b, 22)
	prk = C.HkdfSha256.extract(hex("000102030405060708090a0b0c"), ikm)
	okm1 = C.HkdfSha256.expand(prk, hex("f0f1f2f3f4f5f6f7f8f9"), 42)?
	# No salt and no info.
	okm3 = C.HkdfSha256.derive({ salt: [], input: ikm, info: [], length: 42 })?
	too_long = C.HkdfSha256.expand(prk, [], 255 * 32 + 1)
	expect_eq(
		(prk, okm1, okm3, too_long),
		(
			hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"),
			hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"),
			hex("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"),
			Err(TooLong),
		),
	)
}

crypto_x25519! = || {
	alice = C.X25519.secret_key_from_bytes(hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))?
	bob = C.X25519.secret_key_from_bytes(hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))?
	alice_public = C.X25519.public_key!(alice)
	bob_public = C.X25519.public_key!(bob)
	from_alice = C.X25519.shared_secret!(alice, bob_public)?
	from_bob = C.X25519.shared_secret!(bob, alice_public)?
	low_order = C.X25519.shared_secret!(alice, C.X25519.public_key_from_bytes(List.repeat(0, 32))?)
	expect_eq(
		(alice_public.to_bytes(), bob_public.to_bytes(), from_alice, from_bob, low_order),
		(
			hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"),
			hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"),
			hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"),
			hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"),
			Err(LowOrderPoint),
		),
	)
}

crypto_chachapoly! = || {
	key = C.ChaChaPoly.key_from_bytes(hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))?
	nonce = C.ChaChaPoly.nonce_from_bytes(hex("070000004041424344454647"))?
	ad = hex("50515253c0c1c2c3c4c5c6c7")
	plaintext = Str.to_utf8("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
	sealed = C.ChaChaPoly.seal!(key, nonce, ad, plaintext)
	want =
		hex(
			"d31a8d34648e60db7b86afbc53ef7ec2 a4aded51296e08fea9e2b5a736ee62d6 3dbea45e8ca9671282fafb69da92728b 1a71de0a9e060b2905d6a5b67ecd3b36 92ddbd7f2d778b8c9803aee328091b58 fab324e4fad675945585808b4831d7bc 3ff4def08e4b7a9de576d26586cec64b 6116 1ae10b594f09e26a7e902ecbd0600691",
		)
	opened = C.ChaChaPoly.open!(key, nonce, ad, sealed)
	flipped = List.concat([U8.bitwise_xor(List.first(sealed) ?? 0, 1)], List.drop_first(sealed, 1))
	tampered = C.ChaChaPoly.open!(key, nonce, ad, flipped)
	other_ad = C.ChaChaPoly.open!(key, nonce, [], sealed)
	expect_eq((sealed == want, opened, tampered, other_ad), (True, Ok(plaintext), Err(Invalid), Err(Invalid)))
}

crypto_aesgcm! = || {
	key = C.AesGcm.key_from_bytes(List.repeat(0, 32))?
	nonce = C.AesGcm.nonce_from_bytes(List.repeat(0, 12))?
	# Test case 13: nothing to encrypt, just the tag.
	empty = C.AesGcm.seal!(key, nonce, [], [])
	# Test case 14: 16 zero bytes.
	block = C.AesGcm.seal!(key, nonce, [], List.repeat(0, 16))
	expect_eq(
		(empty, block, C.AesGcm.open!(key, nonce, [], block)),
		(
			hex("530f8afbc74536b9a963b4f1c4cb738b"),
			hex("cea7403d4d606b6e074ec5d3baf39d18 d0d1c8a799996bf0265b98b5d48ab919"),
			Ok(List.repeat(0, 16)),
		),
	)
}

crypto_ed25519! = || {
	secret = C.Ed25519.secret_key_from_bytes(hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))?
	public = C.Ed25519.public_key!(secret)
	signature = C.Ed25519.sign!(secret, [])
	want_signature = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
	expect_eq(
		(public.to_bytes(), signature, C.Ed25519.verify!(public, [], signature), C.Ed25519.verify!(public, [0], signature)),
		(hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"), want_signature, True, False),
	)
}

crypto_misc! = || {
	# Fresh keys work end to end.
	a = C.X25519.generate!({})
	b = C.X25519.generate!({})
	agreed = C.X25519.shared_secret!(a, C.X25519.public_key!(b))? == C.X25519.shared_secret!(b, C.X25519.public_key!(a))?
	key = C.ChaChaPoly.generate!({})
	nonce = C.ChaChaPoly.nonce_from_bytes(List.repeat(1, 12))?
	round_trip = C.ChaChaPoly.open!(key, nonce, [], C.ChaChaPoly.seal!(key, nonce, [], Str.to_utf8("hi")))
	signer = C.Ed25519.generate!({})
	signed = C.Ed25519.verify!(C.Ed25519.public_key!(signer), [1, 2, 3], C.Ed25519.sign!(signer, [1, 2, 3]))
	# Secret keys have no `==` (on purpose), so match the error.
	short =
		# From random bytes, so the compiler can't settle it in advance.
		match C.X25519.secret_key_from_bytes(Random.bytes!(3)?) {
			Err(WrongLength(lengths)) => Err(WrongLength(lengths))
			Ok(_) => Ok({})
		}
	secret_shown = Str.inspect(a)
	expect_eq(
		(agreed, round_trip, signed, short, C.constant_time_eq!([1, 2], [1, 2]), C.constant_time_eq!([1, 2], [1, 3]), C.constant_time_eq!([1], [1, 1]), Str.contains(secret_shown, "opaque")),
		(True, Ok(Str.to_utf8("hi")), True, Err(WrongLength({ expected: 32, actual: 3 })), True, False, False, True),
	)
}

## A responder on `listener` for one connection, with `config`: it runs
## the handshake with `payloads`, then echoes lines until the end, reporting
## the handshake's outcome on the channel returned.
noise_responder! = |listener, config, payloads| {
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		tcp = listener.accept!()?
		match Noise.handshake!(tcp, config, payloads) {
			Ok(done) => {
				_ = report_tx.send!(Ok({ handshake_hash: done.handshake_hash, remote_static_key: done.remote_static_key, payloads: done.payloads }))
				var $reader = Framing.reader(done.stream)
				while True {
					match $reader.read_line!() {
						Ok((line, next)) => {
							done.stream.write_str!("echo: ${line}\n")?
							$reader = next
						}
						Err(_) => break
					}
				}
				Ok({})
			}
			Err(err) => {
				_ = report_tx.send!(Err(Str.inspect(err)))
				Ok({})
			}
		}
	})?
	Ok(report)
}

key_bytes = |key|
	match key {
		Key(public) => public.to_bytes()
		NoKey => []
	}

noise_xx_tcp! = || {
	server_key = C.X25519.generate!({})
	client_key = C.X25519.generate!({})
	(listener, address) = listen_anywhere!()?
	report = noise_responder!(listener, Noise.config(XX, Responder).with_static_key(server_key).with_prologue(Str.to_utf8("test v1")), [Str.to_utf8("hi from the responder")])?
	tcp = Tcp.connect!(address)?
	tcp.set_read_timeout!(Millis(5000))?
	done = Noise.handshake!(tcp, Noise.config(XX, Initiator).with_static_key(client_key).with_prologue(Str.to_utf8("test v1")), [[], Str.to_utf8("hi from the initiator")])?
	reported = report.receive_timeout!(Time.seconds(5))?
	server =
		match reported {
			Ok(value) => value
			Err(message) => return Err(Unexpected(message))
		}
	done.stream.write_str!("one\ntwo\n")?
	var $reader = Framing.reader(done.stream)
	(first, r1) = $reader.read_line!()?
	(second, _) = r1.read_line!()?
	expect_eq(
		(
			key_bytes(done.remote_static_key) == C.X25519.public_key!(server_key).to_bytes(),
			key_bytes(server.remote_static_key) == C.X25519.public_key!(client_key).to_bytes(),
			done.handshake_hash == server.handshake_hash,
			List.map(done.payloads, Str.from_utf8_lossy),
			List.map(server.payloads, Str.from_utf8_lossy),
			(first, second),
		),
		# In XX the responder writes one message (the second), the initiator two.
		(True, True, True, ["hi from the responder"], ["", "hi from the initiator"], ("echo: one", "echo: two")),
	)
}

# 200,000 bytes in one write: several Noise messages, one line.
noise_large_write! = || {
	(listener, address) = listen_anywhere!()?
	report = noise_responder!(listener, Noise.config(NN, Responder), [])?
	tcp = Tcp.connect!(address)?
	tcp.set_read_timeout!(Millis(5000))?
	done = Noise.handshake!(tcp, Noise.config(NN, Initiator), [])?
	reported = report.receive_timeout!(Time.seconds(5))?
	_ =
		match reported {
			Ok(value) => value
			Err(message) => return Err(Unexpected(message))
		}
	done.stream.write!(List.append(List.repeat(120, 200000), 10))?
	(line, _) = Framing.reader_with_max(done.stream, 300000).read_line!()?
	expect_eq(Str.count_utf8_bytes(line), 200006)
}

noise_wrong_keys! = || {
	server_key = C.X25519.generate!({})
	someone_else = C.X25519.generate!({})
	(listener, address) = listen_anywhere!()?
	report = noise_responder!(listener, Noise.config(IK, Responder).with_static_key(server_key), [])?
	tcp = Tcp.connect!(address)?
	tcp.set_read_timeout!(Millis(5000))?
	# The initiator thinks the server's key is someone else's.
	wrong_key = Noise.handshake!(tcp, Noise.config(IK, Initiator).with_static_key(C.X25519.generate!({})).with_remote_static_key(C.X25519.public_key!(someone_else)), [])
	server_saw = report.receive_timeout!(Time.seconds(5))?
	(psk_listener, psk_address) = listen_anywhere!()?
	psk_report = noise_responder!(psk_listener, Noise.config(NN, Responder).with_psk(0, List.repeat(1, 32)), [])?
	psk_tcp = Tcp.connect!(psk_address)?
	psk_tcp.set_read_timeout!(Millis(5000))?
	wrong_psk = Noise.handshake!(psk_tcp, Noise.config(NN, Initiator).with_psk(0, List.repeat(2, 32)), [])
	psk_server_saw = psk_report.receive_timeout!(Time.seconds(5))?
	# The initiator's first message doesn't authenticate at the responder,
	# which gives up; the initiator sees the stream end.
	failed = |result|
		match result {
			Err(_) => True
			Ok(_) => False
		}
	expect_eq(
		(failed(wrong_key), Str.inspect(server_saw), failed(wrong_psk), Str.inspect(psk_server_saw)),
		(True, "Err(\"Invalid\")", True, "Err(\"Invalid\")"),
	)
}

# A relay between the two flips one byte in the first transport message.
noise_tampered! = || {
	(listener, address) = listen_anywhere!()?
	(result_tx, result) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		tcp = listener.accept!()?
		done = Noise.handshake!(tcp, Noise.config(NN, Responder), [])?
		_ = result_tx.send!(done.stream.read!(100))
		Ok({})
	})?
	(relay, relay_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		client = relay.accept!()?
		upstream = Tcp.connect!(address)?
		# Pass the handshake through (NN: 2 + 32 bytes, then 2 + 48 back), then
		# flip the last byte of the next message.
		upstream.write!(read_exactly_tcp!(client, 34)?)?
		client.write!(read_exactly_tcp!(upstream, 50)?)?
		message = read_exactly_tcp!(client, 2 + 5 + 16)?
		last = List.len(message) - 1
		upstream.write!(List.concat(List.take_first(message, last), [U8.bitwise_xor(List.last(message) ?? 0, 1)]))?
		Time.sleep!(Time.seconds(2))?
		client.close!()
		upstream.close!()
		Ok({})
	})?
	tcp = Tcp.connect!(relay_address)?
	tcp.set_read_timeout!(Millis(5000))?
	done = Noise.handshake!(tcp, Noise.config(NN, Initiator), [])?
	done.stream.write_str!("hello")?
	match result.receive_timeout!(Time.seconds(5))? {
		Err(NoiseErr(Other(message))) => expect_eq(Str.contains(message, "authenticate"), True)
		other => Err(Unexpected(Str.inspect(other)))
	}
}

read_exactly_tcp! = |stream, count| {
	var $bytes = []
	while List.len($bytes) < count {
		chunk = stream.read!(count - List.len($bytes))?
		if List.is_empty(chunk) {
			return Err(Unexpected("ended early"))
		}
		$bytes = List.concat($bytes, chunk)
	}
	Ok($bytes)
}

noise_unix! = || {
	path = "/tmp/roc-net-tests-noise.sock"
	listener = Unix.listen!(path)?
	report = noise_responder!(listener, Noise.config(NN, Responder), [])?
	unix = Unix.connect!(path)?
	done = Noise.handshake!(unix, Noise.config(NN, Initiator), [])?
	reported = report.receive_timeout!(Time.seconds(5))?
	_ =
		match reported {
			Ok(value) => value
			Err(message) => return Err(Unexpected(message))
		}
	done.stream.write_str!("over unix\n")?
	(line, _) = Framing.reader(done.stream).read_line!()?
	expect_eq(line, "echo: over unix")
}

bytes_hex! = || {
	random = Random.bytes!(32)?
	odd = Bytes.from_hex("abc")
	bad = Bytes.from_hex("0g")
	expect_eq(
		(Bytes.to_hex([0, 10, 255, 16]), Bytes.from_hex("000aff10"), Bytes.from_hex("0AFF"), Bytes.to_hex([]), Bytes.from_hex(Bytes.to_hex(random)) == Ok(random), odd, bad),
		("000aff10", Ok([0, 10, 255, 16]), Ok([10, 255]), "", True, Err(InvalidHex({ index: 3 })), Err(InvalidHex({ index: 1 }))),
	)
}

# A finished NN handshake, then three messages decrypted out of order, as a
# datagram transport would deliver them, each with its nonce set first.
noise_with_nonce! = || {
	initiator = Noise.start!(Noise.config(NN, Initiator))?
	responder = Noise.start!(Noise.config(NN, Responder))?
	(m1, i2) = initiator.write_message!([])?
	(_, r2) = responder.read_message!(m1)?
	(m2, r3) = r2.write_message!([])?
	(_, i3) = i2.read_message!(m2)?
	sending = i3.finish()?.send
	receiving = r3.finish()?.receive
	(c0, s1) = sending.encrypt!([], Str.to_utf8("zero"))?
	(c1, s2) = s1.encrypt!([], Str.to_utf8("one"))?
	(c2, s3) = s2.encrypt!([], Str.to_utf8("two"))?
	(p2, _) = receiving.with_nonce(2).decrypt!([], c2)?
	(p0, after_zero) = receiving.with_nonce(0).decrypt!([], c0)?
	(p1, _) = receiving.with_nonce(1).decrypt!([], c1)?
	wrong =
		match receiving.with_nonce(5).decrypt!([], c1) {
			Err(Invalid) => True
			_ => False
		}
	expect_eq(
		(List.map([p0, p1, p2], Str.from_utf8_lossy), after_zero.nonce(), s3.nonce(), wrong),
		(["zero", "one", "two"], 1, 3, True),
	)
}

# The trap from a relay: a writer in the scope waits for messages; the body
# reads until the peer leaves and returns Ok. Without cancel_all! the scope
# would wait for the writer forever.
scope_cancel_all! = || {
	(outbox, inbox) = Channel.new!(1)?
	start = Time.now!()
	(writer_ended, body) =
		Task.scope!(|scope| {
			writer = scope.spawn!(|| {
				_ = inbox.receive!()?
				Ok({})
			})?
			Time.sleep!(Time.millis(20))?
			scope.cancel_all!()
			Ok((writer.join!(), "body done"))
		})?
	# Used only now, so the channel stays open (and the writer waiting)
	# throughout: an unused sender would be released, closing it at once.
	outbox.close!()
	expect_eq((writer_ended, body, start.elapsed!().to_millis() < 2000), (Err(Cancelled), "body done", True))
}

## A path in the temporary directory that nothing else uses.
temp_path! = |label| {
	dir = Env.var!("TMPDIR") ?? "/tmp"
	base = if Str.ends_with(dir, "/") dir else "${dir}/"
	"${base}roc-net-test-${label}-${Bytes.to_hex(Bytes.u64_be(Random.u64!()))}"
}

file_round_trip! = || {
	path = temp_path!("round-trip")
	before = File.exists!(path)?
	File.write_utf8!(path, "one\n")?
	first = File.read_utf8!(path)?
	File.append_utf8!(path, "two\n")?
	appended = File.read_utf8!(path)?
	File.write_bytes!(path, [0, 255])?
	replaced = File.read_bytes!(path)?
	during = File.exists!(path)?
	File.delete!(path)?
	after = File.exists!(path)?
	again = shown(File.delete!(path))
	expect_eq(
		(before, first, appended, replaced, during, after, again),
		(False, "one\n", "one\ntwo\n", [0, 255], True, False, "Err(FileErr(NotFound))"),
	)
}

file_write_new! = || {
	path = temp_path!("new")
	File.write_new!(path, Str.to_utf8("first"), 0o600)?
	second = shown(File.write_new!(path, Str.to_utf8("second"), 0o600))
	kept = File.read_utf8!(path)?
	File.delete!(path)?
	expect_eq((second, kept), ("Err(FileErr(AlreadyExists))", "first"))
}

file_write_atomic! = || {
	path = temp_path!("atomic")
	File.write_atomic!(path, Str.to_utf8("created"), 0o644)?
	created = File.read_utf8!(path)?
	File.write_atomic!(path, Str.to_utf8("replaced"), 0o600)?
	replaced = File.read_utf8!(path)?
	File.delete!(path)?
	# Into a directory that doesn't exist: the temporary file can't be made.
	missing = shown(File.write_atomic!("${path}/nested", [1], 0o600))
	expect_eq((created, replaced, missing), ("created", "replaced", "Err(FileErr(NotFound))"))
}

file_rename! = || {
	from = temp_path!("from")
	to = temp_path!("to")
	File.write_utf8!(from, "moved")?
	File.write_utf8!(to, "old")?
	File.rename!(from, to)?
	result = (File.exists!(from)?, File.read_utf8!(to)?)
	File.delete!(to)?
	expect_eq(result, (False, "moved"))
}

file_errors! = || {
	dir = Env.var!("TMPDIR") ?? "/tmp"
	missing = shown(File.read_bytes!("/nonexistent-roc-net/file"))
	write_into_missing = shown(File.write_bytes!("/nonexistent-roc-net/file", []))
	reading_a_directory =
		match File.read_bytes!(dir) {
			Err(FileErr(Other(_))) => True
			_ => False
		}
	path = temp_path!("bad-utf8")
	File.write_bytes!(path, [104, 105, 255])?
	bad =
		match File.read_utf8!(path) {
			Err(BadUtf8({ index, .. })) => Ok(index)
			_ => Err({})
		}
	File.delete!(path)?
	expect_eq(
		(missing, write_into_missing, reading_a_directory, bad),
		("Err(FileErr(NotFound))", "Err(FileErr(NotFound))", True, Ok(2)),
	)
}

# Every task's file calls wait on helper threads, so on one worker thread
# they still overlap rather than queue behind each other's disk waits.
file_many_tasks! = || {
	results =
		Task.scope!(|scope| {
			var $handles = []
			var $i = 0
			while $i < 20 {
				i : U64
				i = $i
				$i = $i + 1
				handle = scope.spawn!(|| {
					path = temp_path!("task-${i.to_str()}")
					File.write_utf8!(path, "task ${i.to_str()}")?
					text = File.read_utf8!(path)?
					File.delete!(path)?
					Ok(text)
				})?
				$handles = List.append($handles, handle)
			}
			var $texts = []
			for handle in $handles {
				$texts = List.append($texts, handle.join!()?)
			}
			Ok($texts)
		})?
	expect_eq((List.len(results), List.first(results), List.last(results)), (20, Ok("task 0"), Ok("task 19")))
}

env_var! = || {
	path = Env.var!("PATH")?
	expect_eq(
		(Str.is_empty(path), Env.var!("ROC_NET_TEST_SURELY_UNSET"), Env.var!(""), Env.var!("A=B")),
		(False, Err(VarNotFound("ROC_NET_TEST_SURELY_UNSET")), Err(VarNotFound("")), Err(VarNotFound("A=B"))),
	)
}

## A result as text, for comparing results whose errors can't be compared
## with `==` (like `IOErr`).
shown = |result|
	match result {
		Ok(_) => "Ok"
		Err(err) => "Err(${Str.inspect(err)})"
	}

## An NN initiator over a plain TCP stream through the sans-I/O layer, so a
## test controls exactly when each byte of a transport message goes out.
## Returns the sending cipher state.
raw_nn_initiator! = |tcp| {
	first = Noise.start!(Noise.config(NN, Initiator))?
	(m1, second) = first.write_message!([])?
	tcp.write!(List.concat(Bytes.u16_be(List.len(m1).to_u16_wrap()), m1))?
	(header, reader) = Framing.reader(tcp).read_exactly!(2)?
	len = Bytes.u16_be_at(header, 0)?
	(m2, _) = reader.read_exactly!(len.to_u64())?
	(_, done) = second.read_message!(m2)?
	Ok(done.finish()?.send)
}

## An NN responder's `Noise.Stream`, from the next connection on `listener`.
noise_accept! = |listener| {
	(streams_tx, streams) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		tcp = listener.accept!()?
		tcp.set_read_timeout!(Millis(5000))?
		done = Noise.handshake!(tcp, Noise.config(NN, Responder), [])?
		streams_tx.send!(done.stream)?
		Ok({})
	})?
	Ok(streams)
}

noise_select_partial! = || {
	(listener, address) = listen_anywhere!()?
	streams = noise_accept!(listener)?
	tcp = Tcp.connect!(address)?
	send = raw_nn_initiator!(tcp)?
	server = streams.receive_timeout!(Time.seconds(5))?
	(sealed, _) = send.encrypt!([], Str.to_utf8("whole"))?
	frame = List.concat(Bytes.u16_be(List.len(sealed).to_u16_wrap()), sealed)
	wait! = ||
		match Select.new({}).on_read(server, 100, |result| Read(result)).on_timeout(Time.millis(100), || Nothing).wait!()? {
			Nothing => Ok("nothing")
			Read(Ok(bytes)) => Ok(Str.from_utf8_lossy(bytes))
			Read(Err(err)) => Ok(Str.inspect(err))
		}
	before = wait!()?
	tcp.write!(List.take_first(frame, 5))?
	partway = wait!()?
	tcp.write!(List.drop_first(frame, 5))?
	after = wait!()?
	expect_eq((before, partway, after), ("nothing", "nothing", "whole"))
}

# The relay's shape: one task, a Select over the connection's lines and an
# outbox, instead of a task per direction.
noise_select_with_channel! = || {
	(listener, address) = listen_anywhere!()?
	streams = noise_accept!(listener)?
	(outbox, inbox) = Channel.new!(4)?
	_ = Task.spawn!(|| {
		server = streams.receive_timeout!(Time.seconds(5))?
		var $reader = Framing.reader(server)
		while True {
			next =
				Select.new({})
					.on_line($reader, |result| Line(result))
					.on_receive(inbox, |result| Pushed(result))
					.wait!()?
			match next {
				Line(Ok((line, rest))) => {
					server.write_str!("echo: ${line}\n")?
					$reader = rest
				}
				Line(Err(EndOfStream)) => break
				Line(Err(err)) => return Err(LineFailed(Str.inspect(err)))
				Pushed(Ok(text)) => server.write_str!("push: ${text}\n")?
				Pushed(Err(ChannelClosed)) => break
			}
		}
		Ok({})
	})?
	tcp = Tcp.connect!(address)?
	tcp.set_read_timeout!(Millis(5000))?
	client = Noise.handshake!(tcp, Noise.config(NN, Initiator), [])?.stream
	client.write_str!("one\n")?
	(first, r1) = Framing.reader(client).read_line!()?
	outbox.send!("from the channel")?
	(second, r2) = r1.read_line!()?
	# Two lines in one message: the second waits in the reader's buffer, and
	# the next Select must find it there.
	client.write_str!("two\nthree\n")?
	(third, r3) = r2.read_line!()?
	(fourth, _) = r3.read_line!()?
	# Used until here, so the server's loop doesn't see the outbox close (an
	# end closes after its last use).
	outbox.close!()
	expect_eq([first, second, third, fourth], ["echo: one", "push: from the channel", "echo: two", "echo: three"])
}

noise_pipe! = || {
	(backend_listener, backend_address) = listen_anywhere!()?
	_ = Task.spawn!(|| {
		backend = backend_listener.accept!()?
		(request, _) = Framing.reader(backend).read_to_end!()?
		backend.write!(List.concat(Str.to_utf8("back: "), request))?
		backend.shutdown!(Write)?
		Ok({})
	})?
	(listener, address) = listen_anywhere!()?
	streams = noise_accept!(listener)?
	(report_tx, report) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		client_side = streams.receive_timeout!(Time.seconds(5))?
		backend = Tcp.connect!(backend_address)?
		report_tx.send!(Pipe.copy_both!(client_side, backend))?
		Ok({})
	})?
	tcp = Tcp.connect!(address)?
	tcp.set_read_timeout!(Millis(5000))?
	client = Noise.handshake!(tcp, Noise.config(NN, Initiator), [])?.stream
	client.write_str!("through the pipe")?
	client.shutdown!(Write)?
	(reply, _) = Framing.reader(client).read_to_end!()?
	copied = report.receive_timeout!(Time.seconds(5))?
	counts =
		match copied {
			Ok({ a_to_b, b_to_a }) => Ok((a_to_b, b_to_a))
			Err(err) => Err(Str.inspect(err))
		}
	expect_eq((Str.from_utf8_lossy(reply), counts), ("back: through the pipe", Ok((16, 22))))
}

# A tampered message, then a good one: the good one mustn't be accepted, or
# the tampered one would go missing unnoticed.
noise_stays_failed! = || {
	(listener, address) = listen_anywhere!()?
	streams = noise_accept!(listener)?
	tcp = Tcp.connect!(address)?
	send = raw_nn_initiator!(tcp)?
	server = streams.receive_timeout!(Time.seconds(5))?
	(bad, after_bad) = send.encrypt!([], Str.to_utf8("tampered"))?
	(good, _) = after_bad.encrypt!([], Str.to_utf8("good"))?
	flipped = List.set(bad, 0, U8.bitwise_xor(List.first(bad) ?? 0, 1))?
	frame = |sealed| List.concat(Bytes.u16_be(List.len(sealed).to_u16_wrap()), sealed)
	tcp.write!(List.concat(frame(flipped), frame(good)))?
	first = shown(server.read!(100))
	second = shown(server.read!(100))
	authentic = |text| !Str.contains(text, "authenticate")
	expect_eq((authentic(first), authentic(second)), (False, False))
}

## Two tasks read `stream` with Selects until it ends, while `send!` sends
## `count` one-byte writes in bursts. Every byte must arrive, and no reader
## may sit out a long wait with data still to come (a lost wake-up).
shared_readers! = |stream, count, send!| {
	(totals_tx, totals) = Channel.new!(2)?
	reader! = || {
		var $got = 0
		while True {
			next =
				Select.new({})
					.on_read(stream, 1, |result| Read(result))
					.on_timeout(Time.seconds(5), || Stalled)
					.wait!()?
			match next {
				Read(Ok([])) => break
				Read(Ok(bytes)) => {
					$got = $got + List.len(bytes)
				}
				Read(Err(err)) => return Err(ReadFailed(Str.inspect(err)))
				Stalled => return Err(Stalled)
			}
		}
		totals_tx.send!($got)?
		Ok({})
	}
	first = Task.spawn!(reader!)?
	second = Task.spawn!(reader!)?
	send!()?
	first_result = shown(first.join!())
	second_result = shown(second.join!())
	a = totals.receive_timeout!(Time.seconds(5)) ?? 0
	b = totals.receive_timeout!(Time.seconds(5)) ?? 0
	expect_eq((first_result, second_result, a + b), ("Ok", "Ok", count))
}

## `count` one-byte writes in bursts of 50, a millisecond apart, then the end.
send_in_bursts! = |stream, count| {
	var $sent = 0
	while $sent < count {
		stream.write!([1])?
		$sent = $sent + 1
		if $sent % 50 == 0 {
			Time.sleep!(Time.millis(1))?
		}
	}
	stream.shutdown!(Write)
}

noise_shared_readers! = || {
	(listener, address) = listen_anywhere!()?
	streams = noise_accept!(listener)?
	tcp = Tcp.connect!(address)?
	client = Noise.handshake!(tcp, Noise.config(NN, Initiator), [])?.stream
	server = streams.receive_timeout!(Time.seconds(5))?
	shared_readers!(server, 2000, || send_in_bursts!(client, 2000))
}

tls_shared_readers! = || {
	(listener, address) = tls_listen_anywhere!()?
	(streams_tx, streams) = Channel.new!(1)?
	_ = Task.spawn!(|| {
		stream = listener.accept!()?
		# Connecting waits for the handshake, so this side must do its part.
		stream.handshake!()?
		streams_tx.send!(stream)?
		Ok({})
	})?
	client = Tls.connect_with!(address, trusting_test_ca)?
	server = streams.receive_timeout!(Time.seconds(5))?
	shared_readers!(server, 2000, || send_in_bursts!(client, 2000))
}

random_bytes_limit! = || {
	most = Random.bytes!(16777216)?
	refused =
		match Random.bytes!(16777217) {
			Err(TooManyBytes(limits)) => Ok(limits)
			_ => Err({})
		}
	expect_eq((List.len(most), refused), (16777216, Ok({ requested: 16777217, max: 16777216 })))
}
