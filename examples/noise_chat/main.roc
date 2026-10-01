app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Bytes
import pf.Cryptography as C
import pf.Env
import pf.File
import pf.Framing
import pf.Noise
import pf.Random
import pf.Select
import pf.Stdout
import pf.Tcp

# Demonstrates: an end-to-end encrypted chat between two people over Noise
# (the XX pattern), with no server in between. Each side has a long-term
# identity key and sees the other's fingerprint, and sends its name in its
# (encrypted) handshake payload.
#
# Usage:
#   noise_chat listen ADDRESS NAME     # wait for the other person
#   noise_chat connect ADDRESS NAME    # connect to them
#
# For example `noise_chat listen 0.0.0.0:7000 ada` in one terminal and
# `noise_chat connect 127.0.0.1:7000 grace` in another. Lines you type go to
# the other side; Ctrl-D or /quit leaves.
#
# Your identity key is made the first time and kept in ~/.noise_chat_key
# (only you can read it), so your fingerprint stays the same. The first time
# you meet someone, compare fingerprints some other way (in person, on a
# call): if they match, nobody is in the middle. Their key is then kept in
# ~/.noise_chat_known_peers, and if someone using that name ever shows up
# with a different key, you're warned. NOISE_CHAT_KEY and
# NOISE_CHAT_KNOWN_PEERS choose other files (to run two on one machine).
#
# The chat's wire format, lines of UTF-8 text inside Noise transport
# messages, and its files are this example's own: the platform only
# provides the Noise handshake and stream, files, and Select.

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
	home = Env.var!("HOME") ?? "."
	key_path = Env.var!("NOISE_CHAT_KEY") ?? "${home}/.noise_chat_key"
	peers_path = Env.var!("NOISE_CHAT_KNOWN_PEERS") ?? "${home}/.noise_chat_known_peers"
	identity = load_identity!(key_path)?
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
	peer_key =
		match done.remote_static_key {
			Key(key) => key
			# XX always sends both static keys.
			NoKey => crash "an XX handshake ended without the peer's static key"
		}
	Stdout.line!("Connected to ${peer_name}. Their fingerprint: ${fingerprint(peer_key)}")?
	check_peer!(peers_path, peer_name, peer_key)?
	Stdout.line!("Type to chat; Ctrl-D or /quit to leave.")?

	stream = done.stream
	stream.set_read_timeout!(NoTimeout)?
	chat!(stream, peer_name)
}

## Wait for whichever comes first, a line you type or a line from the other
## side, until either of you leaves.
chat! = |stream, peer_name| {
	var $reader = Framing.reader_with_max(stream, 4096)
	var $typing = True
	while True {
		next =
			if $typing {
				Select.new({})
					.on_stdin_line(|result| Typed(result))
					.on_line($reader, |result| Received(result))
					.wait!()?
			} else {
				# After we've left, only wait for them to finish.
				Received($reader.read_line!())
			}
		match next {
			Typed(Ok(Line("/quit"))) | Typed(Ok(End)) => {
				# Ending our side of the stream tells them we've left; carry on
				# reading until they close theirs.
				stream.shutdown!(Write)?
				$typing = False
			}
			Typed(Ok(Line(text))) => stream.write_str!("${text}\n")?
			Typed(Err(LineTooLong)) => Stdout.line!("That line is too long to send.")?
			Typed(Err(StdinErr(message))) => return Err(StdinFailed(message))
			Received(Ok((line, rest))) => {
				Stdout.line!("${peer_name}: ${printable(line, 4096)}")?
				$reader = rest
			}
			Received(Err(EndOfStream)) => {
				Stdout.line!("${peer_name} left.")?
				break
			}
			Received(Err(err)) => {
				Stdout.line!("The connection failed: ${Str.inspect(err)}")?
				break
			}
		}
	}
	Ok({})
}

## The identity key kept at `path`, made (and kept) the first time: 32
## random bytes as hex, in a file only its owner can read.
load_identity! = |path| {
	match File.read_utf8!(path) {
		Ok(text) => {
			bytes = Bytes.from_hex(Str.trim(text)) ?? []
			match C.X25519.secret_key_from_bytes(bytes) {
				Ok(key) => Ok(key)
				Err(_) => Err(BadKeyFile(path))
			}
		}
		Err(FileErr(NotFound)) => {
			bytes = Random.bytes!(32)?
			# write_new! refuses an existing file, and the file only appears
			# once it's whole, so two first runs at once can't both make a key:
			# the second reads the first one's.
			match File.write_new!(path, Str.to_utf8("${Bytes.to_hex(bytes)}\n"), 0o600) {
				Ok({}) => {
					Stdout.line!("Made a new identity key in ${path}")?
					match C.X25519.secret_key_from_bytes(bytes) {
						Ok(key) => Ok(key)
						Err(_) => Err(BadKeyFile(path))
					}
				}
				Err(FileErr(AlreadyExists)) => load_identity!(path)
				Err(FileErr(err)) => Err(FileErr(err))
			}
		}
		Err(FileErr(err)) => Err(FileErr(err))
		Err(BadUtf8(_)) => Err(BadKeyFile(path))
	}
}

## Compare `key` with the one kept for `name` in the known-peers file (lines
## of "KEY-HEX NAME"), and remember it if `name` is new.
check_peer! = |path, name, key| {
	key_hex = Bytes.to_hex(key.to_bytes())
	text =
		match File.read_utf8!(path) {
			Ok(t) => t
			Err(FileErr(NotFound)) => ""
			Err(FileErr(err)) => return Err(FileErr(err))
			Err(BadUtf8(_)) => return Err(BadKnownPeersFile(path))
		}
	known =
		List.keep_oks(
			Str.split_on(text, "\n"),
			|line|
				match Str.split_first(line, " ") {
					Ok({ before, after }) => Ok((before, after))
					Err(_) => Err({})
				},
		)
	match List.find_first(known, |(_, n)| n == name) {
		Ok((kept, _)) if kept == key_hex => Stdout.line!("${name}'s key matches the one you kept.")
		Ok(_) => {
			Stdout.line!("WARNING: ${name}'s key is NOT the one you kept for them. Someone may be")?
			Stdout.line!("pretending to be them, or they have a new key. Check their fingerprint")?
			Stdout.line!("with them before trusting anything they say. (To accept the new key,")?
			Stdout.line!("remove their line from ${path}.)")
		}
		Err(_) => {
			File.append_utf8!(path, "${key_hex} ${name}\n")?
			Stdout.line!("First time talking to ${name}: compare fingerprints with them another way.")
		}
	}
}

## A readable form of a public key for people to compare: the first 16
## bytes (128 bits) of its SHA-256, as hex in groups of four. Shorter would
## be easier to read out, but people compare these once and then rely on
## them, so they must be too long to find a match for.
fingerprint = |key| {
	hex = Str.to_utf8(Crypto.SHA256.hash(key.to_bytes()).to_hex())
	groups = List.map([0, 4, 8, 12, 16, 20, 24, 28], |start| Str.from_utf8_lossy(List.sublist(hex, { start, len: 4 })))
	Str.join_with(groups, " ")
}

## `text` with control characters replaced by `?` (so the other side can't
## send terminal escape sequences), cut to `max` bytes.
printable = |text, max| {
	bytes = List.map(Str.to_utf8(text), |b| if b < 32 or b == 127 63 else b)
	Str.from_utf8_lossy(List.take_first(bytes, max))
}
