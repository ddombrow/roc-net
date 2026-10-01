app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Cryptography as C
import pf.Framing
import pf.Noise
import pf.Stdin
import pf.Stdout
import pf.Task
import pf.Tcp

# Demonstrates: an end-to-end encrypted chat between two people over Noise
# (the XX pattern), with no server in between. Each side has a static key
# and sees the other's fingerprint, and sends its name in its (encrypted)
# handshake payload.
#
# Usage:
#   noise_chat listen ADDRESS NAME     # wait for the other person
#   noise_chat connect ADDRESS NAME    # connect to them
#
# For example `noise_chat listen 0.0.0.0:7000 ada` in one terminal and
# `noise_chat connect 127.0.0.1:7000 grace` in another. Compare the
# fingerprints you both see some other way (in person, on a call): if they
# match, nobody is in the middle. Lines you type go to the other side;
# Ctrl-D or /quit leaves.
#
# The identity key is new each run, so fingerprints change every time
# (keeping one needs files, planned for 0.5). The chat's wire format, lines
# of UTF-8 text inside Noise transport messages, is this example's own: the
# platform only provides the Noise handshake and stream.

usage = "Usage: noise_chat (listen | connect) ADDRESS NAME"

## Both sides must agree on this, so a different version fails the
## handshake instead of misunderstanding it.
prologue = Str.to_utf8("roc-net noise_chat v1")

main! : List(Str) => Try({}, _)
main! = |args| {
	(mode, address, name) =
		match args {
			[_, m, a, n] if m == "listen" or m == "connect" => (m, a, n)
			_ => {
				Stdout.line!(usage)?
				return Err(Exit(2))
			}
		}
	identity = C.X25519.generate!({})
	Stdout.line!("Your fingerprint:  ${fingerprint(C.X25519.public_key!(identity))}")?

	tcp =
		if mode == "listen" {
			listener = Tcp.listen!(address)?
			Stdout.line!("Waiting for a connection on ${address}...")?
			listener.accept!()?
		} else {
			Tcp.connect!(address)?
		}
	# A handshake must finish promptly; the chat afterwards may be quiet.
	tcp.set_read_timeout!(Millis(10000))?

	# In XX the responder's payload rides in message 2 and the initiator's in
	# message 3, both encrypted by then.
	(role, payloads) =
		if mode == "listen" {
			(Responder, [Str.to_utf8(name)])
		} else {
			(Initiator, [[], Str.to_utf8(name)])
		}
	done = Noise.handshake!(tcp, Noise.config(XX, role).with_static_key(identity).with_prologue(prologue), payloads)?
	peer_name = printable(Str.from_utf8_lossy(List.last(done.payloads) ?? []), 32)
	peer_fingerprint =
		match done.remote_static_key {
			Key(key) => fingerprint(key)
			# XX always sends both static keys.
			NoKey => "(none)"
		}
	Stdout.line!("Connected to ${peer_name}. Their fingerprint: ${peer_fingerprint}")?
	Stdout.line!("Type to chat; Ctrl-D or /quit to leave.")?

	stream = done.stream
	stream.set_read_timeout!(NoTimeout)?
	# What you type goes out from a task of its own, while this one prints
	# what arrives: a Noise.Stream can be read and written at once.
	_ = Task.spawn!(|| send_lines!(stream))?
	receive_lines!(stream, peer_name)
}

## Send each line typed until Ctrl-D or /quit, then end our side of the
## stream, which tells the other side we've left.
send_lines! = |stream| {
	while True {
		match Stdin.read_line!({})? {
			Line("/quit") => break
			Line(text) => stream.write_str!("${text}\n")?
			End => break
		}
	}
	stream.shutdown!(Write)
}

## Print each line from the other side until they leave.
receive_lines! = |stream, peer_name| {
	var $reader = Framing.reader_with_max(stream, 4096)
	while True {
		match $reader.read_line!() {
			Ok((line, next)) => {
				Stdout.line!("${peer_name}: ${printable(line, 4096)}")?
				$reader = next
			}
			Err(EndOfStream) => {
				Stdout.line!("${peer_name} left.")?
				break
			}
			Err(err) => {
				Stdout.line!("The connection failed: ${Str.inspect(err)}")?
				break
			}
		}
	}
	Ok({})
}

## A short, readable form of a public key for people to compare: the first
## 8 bytes of its SHA-256, as hex in groups of four.
fingerprint = |key| {
	hex = Str.to_utf8(Crypto.SHA256.hash(key.to_bytes()).to_hex())
	groups = List.map([0, 4, 8, 12], |start| Str.from_utf8_lossy(List.sublist(hex, { start, len: 4 })))
	Str.join_with(groups, " ")
}

## `text` with control characters replaced by `?` (so the other side can't
## send terminal escape sequences), cut to `max` bytes.
printable = |text, max| {
	bytes = List.map(Str.to_utf8(text), |b| if b < 32 or b == 127 63 else b)
	Str.from_utf8_lossy(List.take_first(bytes, max))
}
