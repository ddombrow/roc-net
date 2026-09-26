app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Bytes
import pf.Framing
import pf.Stdout
import pf.Tcp
import pf.Udp
import Dns

# Demonstrates: a binary protocol over UDP, with retries, reply validation,
# and fallback to TCP when a reply is too big for a datagram.
#
# Usage: dns_client NAME [TYPE] [SERVER]
#   dns_client example.com
#   dns_client gmail.com MX
#   dns_client google.com TXT 8.8.8.8
#   dns_client _xmpp-server._tcp.jabber.org SRV
#
# TYPE is A (default), AAAA, CNAME, MX, NS, PTR, SOA, SRV, TXT, or TYPEnnn.
# SERVER defaults to 1.1.1.1; the port defaults to 53.

main! : List(Str) => Try({}, _)
main! = |args| {
	(name, type_text, server_text) =
		match args {
			[_, n] => (n, "A", "1.1.1.1")
			[_, n, t] => (n, t, "1.1.1.1")
			[_, n, t, s, ..] => (n, t, s)
			_ => {
				Stdout.line!("Usage: dns_client NAME [TYPE] [SERVER]")?
				return Err(Exit(2))
			}
		}
	type = Dns.parse_type(type_text)?
	server = with_default_port(server_text)

	socket = Udp.bind!(if Str.contains(server, "[") "[::]:0" else "0.0.0.0:0")?
	socket.connect!(server)?
	# roc-net has no random numbers yet, so derive the query ID from the local
	# port, which the OS picks per run. A real resolver must use a random ID so
	# attackers can't guess it and forge replies.
	id = query_id(socket.local_addr!()?)
	query = Dns.encode_query(id, name, type)?

	udp_reply =
		match ask_udp!(socket, query, id) {
			Ok(reply) => reply
			Err(NoReply(_)) => {
				Stdout.line!("No reply from ${server} after 3 tries, 2 seconds apart.")?
				return Err(Exit(1))
			}
			Err(UdpErr(ConnectionRefused)) => {
				Stdout.line!("Nothing is answering DNS at ${server}.")?
				return Err(Exit(1))
			}
			Err(err) => return Err(err)
		}
	(reply, transport) =
		if udp_reply.truncated {
			(ask_tcp!(server, query, id)?, "TCP (the UDP reply was truncated)")
		} else {
			(udp_reply, "UDP")
		}

	print!(reply, name, type, server, transport)
}

## Send the query over UDP, retrying twice if no reply arrives within 2
## seconds, and return the first reply that answers it.
ask_udp! = |socket, query, id| {
	socket.set_read_timeout!(Millis(2000))?
	var $attempt = 1
	while $attempt <= 3 {
		socket.send!(query)?
		match wait_for_reply!(socket, id) {
			Ok(reply) => return Ok(reply)
			Err(UdpErr(TimedOut)) => {
				$attempt = $attempt + 1
			}
			Err(err) => return Err(err)
		}
	}
	Err(NoReply("no reply after 3 attempts"))
}

## Receive until a datagram carries our query ID. Anything else (a late reply
## to an earlier attempt, or junk) is ignored.
wait_for_reply! = |socket, id| {
	while True {
		datagram = socket.recv!(65535)?
		match Dns.decode_response(datagram) {
			Ok(reply) if reply.id == id => return Ok(reply)
			_ => {}
		}
	}
	Err(NoReply("unreachable"))
}

## DNS over TCP: each message is preceded by its length as a 2-byte big-endian
## number. Framing's own frames use 4 bytes, so read the two parts directly.
ask_tcp! = |server, query, id| {
	stream = Tcp.connect_timeout!(server, Millis(5000))?
	stream.set_read_timeout!(Millis(5000))?
	stream.write!(List.concat(Bytes.u16_be(List.len(query).to_u16_wrap()), query))?

	reader = Framing.reader(stream)
	(prefix, rest) = reader.read_exactly!(2)?
	(length, _) = Bytes.take_u16_be(prefix)?
	(message, _) = rest.read_exactly!(length.to_u64())?
	reply = Dns.decode_response(message)?
	if reply.id == id Ok(reply) else Err(NoReply("TCP reply had the wrong ID"))
}

print! = |reply, name, type, server, transport| {
	Stdout.line!(";; ${name} ${Dns.type_name(type)} via ${server} over ${transport}")?
	Stdout.line!(";; status: ${Dns.rcode_name(reply.rcode)}, answers: ${List.len(reply.answers).to_str()}, authority: ${List.len(reply.authority).to_str()}, additional: ${List.len(reply.additional).to_str()}")?
	print_section!("ANSWER", reply.answers)?
	print_section!("AUTHORITY", reply.authority)?
	print_section!("ADDITIONAL", reply.additional)
}

print_section! = |title, records| {
	if List.is_empty(records) {
		return Ok({})
	}
	Stdout.line!("\n;; ${title}")?
	for record in records {
		Stdout.line!("${record.name}\t${record.ttl.to_str()}\tIN\t${Dns.type_name(record.type)}\t${record.data}")?
	}
	Ok({})
}

with_default_port : Str -> Str
with_default_port = |server|
	if Str.starts_with(server, "[") {
		if Str.contains(server, "]:") server else "${server}:53"
	} else if Str.contains(server, ":") {
		# More than one colon means a bare IPv6 address.
		if List.len(Str.split_on(server, ":")) > 2 "[${server}]:53" else server
	} else {
		"${server}:53"
	}

query_id : Str -> U16
query_id = |local_addr|
	match Str.split_on(local_addr, ":").last() {
		Ok(port) =>
			match U16.from_str(port) {
				Ok(n) => n
				Err(_) => 1
			}
		Err(_) => 1
	}
