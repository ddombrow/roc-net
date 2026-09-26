app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Dns
import pf.Framing
import pf.Stdout
import pf.Tcp
import pf.Time
import pf.Udp

# End-to-end checks across containers (see compose.yaml): each example server
# runs in its own container, and this client reaches them by service name
# through Docker's DNS, over a real network.

main! : List(Str) => Try({}, _)
main! = |_args| {
	results = [
		check!("dns: service names resolve", resolves_services!),
		check!("tcp: echo across containers", tcp_echo!),
		check!("udp: echo across containers", udp_echo!),
		check!("line protocol: ADD", line_server!),
		check!("chat: broadcast between two users", chat!),
	]
	failed = List.len(List.keep_if(results, |passed| !passed))
	if failed == 0 {
		Stdout.line!("All ${List.len(results).to_str()} end-to-end checks passed")?
		Ok({})
	} else {
		Stdout.line!("${failed.to_str()} of ${List.len(results).to_str()} end-to-end checks failed")?
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
		Err(Mismatch({ expected: Str.inspect(expected), actual: Str.inspect(actual) }))
	}

## Containers start in parallel, so a server may not be listening yet: retry
## connecting for up to 10 seconds.
connect_when_ready! = |address| {
	var $attempt = 0
	while True {
		match Tcp.connect_timeout!(address, Millis(1000)) {
			Ok(stream) => return Ok(stream)
			Err(err) => {
				$attempt = $attempt + 1
				if $attempt >= 50 {
					return Err(err)
				}
				Time.sleep!(Time.millis(200))
			}
		}
	}
	Err(TcpErr(TimedOut))
}

resolves_services! = || {
	for service in ["echo", "udp", "lines", "chat"] {
		addresses = Dns.resolve!(service)?
		if List.is_empty(addresses) {
			return Err(Unexpected("${service} resolved to nothing"))
		}
	}
	Ok({})
}

tcp_echo! = || {
	stream = connect_when_ready!("echo:8080")?
	stream.set_read_timeout!(Millis(5000))?
	stream.write_str!("hello from another container")?
	stream.shutdown!(Write)?
	(reply, _) = Framing.reader(stream).read_to_end!()?
	expect_eq(Str.from_utf8_lossy(reply), "hello from another container")
}

udp_echo! = || {
	socket = Udp.bind!("0.0.0.0:0")?
	socket.set_read_timeout!(Millis(1000))?
	# UDP has no connection to wait for, and a datagram sent before the
	# server is up is simply lost, so retry the whole exchange.
	var $attempt = 0
	while True {
		socket.send_to!(Str.to_utf8("ping over udp"), "udp:8081")?
		match socket.recv_from!(1024) {
			Ok(reply) => return expect_eq(Str.from_utf8_lossy(reply.bytes), "ping over udp")
			Err(err) => {
				$attempt = $attempt + 1
				if $attempt >= 10 {
					return Err(err)
				}
			}
		}
	}
	Ok({})
}

line_server! = || {
	stream = connect_when_ready!("lines:8082")?
	stream.set_read_timeout!(Millis(5000))?
	stream.write_str!("ADD 2 40\nQUIT\n")?
	(answer, next) = Framing.reader(stream).read_line!()?
	(bye, _) = next.read_line!()?
	expect_eq((answer, bye), ("42", "BYE"))
}

## Read lines until one satisfies `wanted`, or fail after the read timeout.
wait_for_line! = |reader, wanted| {
	var $reader = reader
	while True {
		(line, $reader) = $reader.read_line!()?
		if wanted(line) {
			return Ok($reader)
		}
	}
	Ok($reader)
}

chat! = || {
	alice = connect_when_ready!("chat:8083")?
	bob = connect_when_ready!("chat:8083")?
	alice.set_read_timeout!(Millis(5000))?
	bob.set_read_timeout!(Millis(5000))?

	alice.write_str!("alice\n")?
	alice_in = wait_for_line!(Framing.reader(alice), |line| Str.contains(line, "here."))?
	bob.write_str!("bob\n")?
	bob_in = wait_for_line!(Framing.reader(bob), |line| Str.contains(line, "here."))?
	_ = wait_for_line!(alice_in, |line| line == "* bob joined")?

	alice.write_str!("hi bob\n")?
	_ = wait_for_line!(bob_in, |line| line == "<alice> hi bob")?
	Ok({})
}
