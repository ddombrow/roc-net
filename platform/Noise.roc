import Bytes
import Cryptography
import Host
import IOErr

## The Noise Protocol Framework (revision 34, https://noiseprotocol.org):
## handshakes that authenticate two parties and agree on keys, from a
## pattern of Diffie-Hellman operations, followed by encrypted transport
## messages.
##
## Over a connection, `handshake!` does it all and gives back a `Noise.Stream`,
## which has the same methods as `Tcp.Stream` (so `Framing` works over it):
##
## ```roc
## tcp = Tcp.connect!(address)?
## config = Noise.config(XX, Initiator).with_static_key(my_key)
## { stream, remote_static_key } = Noise.handshake!(tcp, config, [])?
## # Check `remote_static_key` is who you expected, then:
## stream.write_str!("hello")?
## ```
##
## Underneath is the specification's own interface, without any I/O, for
## protocols that frame or carry handshake messages their own way: a
## `Handshake` writes and reads handshake messages, then `finish` gives a
## `CipherState` for each direction (which `wrap!` turns into a stream).
##
## ```roc
## initiator = Noise.start!(Noise.config(XX, Initiator).with_static_key(my_key))?
## (first, $initiator) = initiator.write_message!([])?
## # ... send `first`, receive the reply, and so on until finished:
## { send, receive, remote_static_key, handshake_hash } = $initiator.finish()?
## ```
##
## - Patterns: the one-way `N`, `K`, `X` and the interactive `NN`, `NK`,
##   `NX`, `KN`, `KK`, `KX`, `XN`, `XK`, `XX`, `IN`, `IK`, `IX`, each with any
##   pre-shared keys (`with_psk`, as in `Noise_XXpsk3`).
## - Suite: `25519` for Diffie-Hellman, `ChaChaPoly` (the default) or
##   `AESGCM` for encryption, `SHA256` for hashing: for example
##   `Noise_XX_25519_ChaChaPoly_SHA256` (`Config.protocol_name`).
## - Handshake and transport messages are at most 65,535 bytes, as the
##   specification requires.
Noise := [].{

	## A handshake pattern (specification §7.4, §7.5).
	Pattern : [N, K, X, NN, NK, NX, KN, KK, KX, XN, XK, XX, IN, IK, IX]

	## Which side of the handshake this is: the initiator sends first.
	Role : [Initiator, Responder]

	## The AEAD cipher.
	Cipher : [ChaChaPoly, AesGcm]

	## What goes into a handshake. Start from `config` and add the keys the
	## pattern needs.
	Config :: {
		pattern : Pattern,
		role : Role,
		cipher : Cipher,
		prologue : List(U8),
		static_key : [NoKey, Key(Cryptography.X25519.SecretKey)],
		remote_static_key : [NoKey, Key(Cryptography.X25519.PublicKey)],
		psks : List({ position : U64, key : List(U8) }),
		ephemeral : [Random, Fixed(Cryptography.X25519.SecretKey)],
	}.{

		## This side's long-term (static) key, for patterns in which it has
		## one (`X`, `K` or `I` on its side, as in `XX`, `IK`).
		with_static_key : Config, Cryptography.X25519.SecretKey -> Config
		with_static_key = |Config.(c), key| Config.({ ..c, static_key: Key(key) })

		## The other side's static public key, for patterns in which it's
		## known in advance (`K` on its side, as in `NK`, `IK`).
		with_remote_static_key : Config, Cryptography.X25519.PublicKey -> Config
		with_remote_static_key = |Config.(c), key| Config.({ ..c, remote_static_key: Key(key) })

		## Data both sides must agree on (a protocol version, say) without
		## sending it: the handshake fails unless both use the same.
		with_prologue : Config, List(U8) -> Config
		with_prologue = |Config.(c), prologue| Config.({ ..c, prologue })

		## A 32-byte pre-shared key, used at `position` (0: at the start of
		## the first message; n: at the end of the nth), as in `XXpsk3`.
		with_psk : Config, U64, List(U8) -> Config
		with_psk = |Config.(c), position, key| Config.({ ..c, psks: List.append(c.psks, { position, key }) })

		## AES-256-GCM instead of ChaCha20-Poly1305.
		with_cipher : Config, Cipher -> Config
		with_cipher = |Config.(c), cipher| Config.({ ..c, cipher })

		## Use this ephemeral key instead of a new random one. For test
		## vectors only: reusing an ephemeral key breaks the handshake's
		## security.
		with_fixed_ephemeral_key_for_testing : Config, Cryptography.X25519.SecretKey -> Config
		with_fixed_ephemeral_key_for_testing = |Config.(c), key| Config.({ ..c, ephemeral: Fixed(key) })

		## The full protocol name, such as `Noise_XXpsk3_25519_ChaChaPoly_SHA256`.
		protocol_name : Config -> Str
		protocol_name = |Config.(c)| {
			positions = List.map(sort_psks(c.psks), |psk| "psk${psk.position.to_str()}")
			cipher =
				match c.cipher {
					ChaChaPoly => "ChaChaPoly"
					AesGcm => "AESGCM"
				}
			"Noise_${pattern_name(c.pattern)}${Str.join_with(positions, "+")}_25519_${cipher}_SHA256"
		}
	}

	## A handshake with `pattern`, as `role`, using ChaCha20-Poly1305 and no
	## prologue or pre-shared keys.
	config : Pattern, Role -> Config
	config = |pattern, role|
		Config.({
			pattern,
			role,
			cipher: ChaChaPoly,
			prologue: [],
			static_key: NoKey,
			remote_static_key: NoKey,
			psks: [],
			ephemeral: Random,
		})

	## One direction's encryption after the handshake (specification §5.1):
	## a key and a message counter, used as the nonce. Messages must be
	## decrypted in the order they were encrypted, unless the transport
	## carries each message's nonce: then `with_nonce` sets it first.
	CipherState :: { cipher : Cipher, key : List(U8), nonce : U64 }.{

		## `plaintext` encrypted (with a 16-byte tag), and the state for the
		## next message.
		encrypt! : CipherState, List(U8), List(U8) => Try((List(U8), CipherState), [NonceExhausted])
		encrypt! = |CipherState.(c), associated_data, plaintext|
			if c.nonce == U64.highest {
				Err(NonceExhausted)
			} else {
				Ok((seal!(c.cipher, c.key, c.nonce, associated_data, plaintext), CipherState.({ ..c, nonce: c.nonce + 1 })))
			}

		## The plaintext of the next message, and the state for the one after;
		## `Invalid` if it doesn't authenticate (tampered with, or out of
		## order).
		decrypt! : CipherState, List(U8), List(U8) => Try((List(U8), CipherState), [Invalid, NonceExhausted])
		decrypt! = |CipherState.(c), associated_data, ciphertext|
			if c.nonce == U64.highest {
				Err(NonceExhausted)
			} else {
				plaintext = open!(c.cipher, c.key, c.nonce, associated_data, ciphertext)?
				Ok((plaintext, CipherState.({ ..c, nonce: c.nonce + 1 })))
			}

		## The nonce the next `encrypt!` or `decrypt!` will use.
		nonce : CipherState -> U64
		nonce = |CipherState.(c)| c.nonce

		## The state with its nonce set to `n` (the specification's
		## `SetNonce`), for transports that can lose or reorder messages
		## (§11.4): send each message's nonce with it, and set it before
		## decrypting. Never encrypt twice with the same nonce, and keep
		## track of the nonces already accepted (a replay window) yourself:
		## this doesn't.
		with_nonce : CipherState, U64 -> CipherState
		with_nonce = |CipherState.(c), n| CipherState.({ ..c, nonce: n })

		## The key, cipher and next nonce, for moving the state into the
		## host (`Noise.Stream`).
		parts : CipherState -> { cipher : Cipher, key : List(U8), nonce : U64 }
		parts = |CipherState.(c)| c
	}

	## A handshake in progress (specification §5.3).
	Handshake :: {
		role : Role,
		sym : Symmetric,
		s : [NoKey, Key(KeyPair)],
		e : [NoKey, Key(KeyPair)],
		rs : [NoKey, Key(Cryptography.X25519.PublicKey)],
		re : [NoKey, Key(Cryptography.X25519.PublicKey)],
		psks : List(List(U8)),
		psk_mode : Bool,
		messages : List(List(Token)),
		index : U64,
		ephemeral : [Random, Fixed(Cryptography.X25519.SecretKey)],
	}.{

		## Write the next handshake message, carrying `payload` (encrypted,
		## once the handshake has a key). Fails with `NotMyTurn` if it's the
		## other side's turn, `Finished` once the handshake is done, and
		## `TooLong` past 65,535 bytes.
		write_message! : Handshake, List(U8) => Try((List(U8), Handshake), [NotMyTurn, Finished, TooLong, LowOrderPoint, NonceExhausted])
		write_message! = |Handshake.(h), payload| {
			tokens = next_tokens(h)?
			var $h = h
			var $out = []
			for token in tokens {
				match token {
					E => {
						pair =
							match $h.ephemeral {
								Fixed(secret) => { secret, public: Cryptography.X25519.public_key!(secret) }
								Random => {
									secret = Cryptography.X25519.generate!({})
									{ secret, public: Cryptography.X25519.public_key!(secret) }
								}
							}
						public = pair.public.to_bytes()
						$out = List.concat($out, public)
						$h = { ..$h, e: Key(pair), sym: mix_hash($h.sym, public) }
						if $h.psk_mode {
							$h = { ..$h, sym: mix_key($h.sym, public) }
						}
					}
					S => {
						public =
							match $h.s {
								Key(pair) => pair.public.to_bytes()
								NoKey => crash "Noise: no static key to send (start! checks for one)"
							}
						(sealed, sym) = encrypt_and_hash!($h.sym, public)?
						$out = List.concat($out, sealed)
						$h = { ..$h, sym }
					}
					Psk => {
						$h = use_psk($h)
					}
					dh_token => {
						$h = { ..$h, sym: mix_key($h.sym, dh!($h, dh_token)?) }
					}
				}
			}
			(sealed, sym) = encrypt_and_hash!($h.sym, payload)?
			message = List.concat($out, sealed)
			if List.len(message) > 65535 {
				return Err(TooLong)
			}
			Ok((message, Handshake.({ ..$h, sym, index: $h.index + 1 })))
		}

		## Read the other side's next handshake message and return its
		## payload. Fails with `Invalid` if it doesn't authenticate (the
		## wrong keys, a different prologue, tampering), `TooShort` if it's
		## cut short, and `NotMyTurn` / `Finished` as for `write_message!`.
		read_message! : Handshake, List(U8) => Try((List(U8), Handshake), [NotMyTurn, Finished, TooLong, TooShort, Invalid, LowOrderPoint, NonceExhausted])
		read_message! = |Handshake.(h), message| {
			if List.len(message) > 65535 {
				return Err(TooLong)
			}
			tokens = next_tokens_to_read(h)?
			var $h = h
			var $rest = message
			for token in tokens {
				match token {
					E => {
						(bytes, rest) = Bytes.take($rest, 32)?
						$rest = rest
						public = public_key(bytes)
						$h = { ..$h, re: Key(public), sym: mix_hash($h.sym, bytes) }
						if $h.psk_mode {
							$h = { ..$h, sym: mix_key($h.sym, bytes) }
						}
					}
					S => {
						length = if has_key($h.sym) 48 else 32
						(sealed, rest) = Bytes.take($rest, length)?
						$rest = rest
						(bytes, sym) = decrypt_and_hash!($h.sym, sealed)?
						$h = { ..$h, rs: Key(public_key(bytes)), sym }
					}
					Psk => {
						$h = use_psk($h)
					}
					dh_token => {
						$h = { ..$h, sym: mix_key($h.sym, dh!($h, dh_token)?) }
					}
				}
			}
			(payload, sym) = decrypt_and_hash!($h.sym, $rest)?
			Ok((payload, Handshake.({ ..$h, sym, index: $h.index + 1 })))
		}

		## Whether every handshake message has been written or read.
		is_finished : Handshake -> Bool
		is_finished = |Handshake.(h)| h.index >= List.len(h.messages)

		## Whether the next message is this side's to write (else, to read).
		is_my_turn : Handshake -> Bool
		is_my_turn = |Handshake.(h)| my_turn(h)

		## The handshake hash so far (`h`): once finished, a value unique to
		## this session that both sides share, for channel binding.
		handshake_hash : Handshake -> List(U8)
		handshake_hash = |Handshake.(h)| h.sym.h

		## The other side's static public key, once the handshake has
		## received (or was given) it.
		remote_static_key : Handshake -> [NoKey, Key(Cryptography.X25519.PublicKey)]
		remote_static_key = |Handshake.(h)| h.rs

		## After the last message: the cipher states for sending and
		## receiving transport messages (specification §5.2, `Split`), the
		## handshake hash, and the other side's static key if it has one.
		finish : Handshake -> Try({ send : CipherState, receive : CipherState, handshake_hash : List(U8), remote_static_key : [NoKey, Key(Cryptography.X25519.PublicKey)] }, [NotFinished])
		finish = |Handshake.(h)|
			if h.index < List.len(h.messages) {
				Err(NotFinished)
			} else {
				(first, second) = hkdf2(h.sym.ck, [])
				c1 = CipherState.({ cipher: h.sym.cipher, key: first, nonce: 0 })
				c2 = CipherState.({ cipher: h.sym.cipher, key: second, nonce: 0 })
				(send, receive) =
					match h.role {
						Initiator => (c1, c2)
						Responder => (c2, c1)
					}
				Ok({ send, receive, handshake_hash: h.sym.h, remote_static_key: h.rs })
			}
	}

	## Begin a handshake. Fails with `MissingKey` if the pattern needs a
	## static key (`with_static_key`) or the other side's
	## (`with_remote_static_key`) that `config` lacks, and `BadPsk` unless
	## every pre-shared key is 32 bytes and each position is used once.
	start! : Config => Try(Handshake, [MissingKey([Static, RemoteStatic]), BadPsk])
	start! = |Config.(c)| {
		shape = pattern_shape(c.pattern)
		psks = sort_psks(c.psks)
		if List.any(psks, |psk| List.len(psk.key) != 32) {
			return Err(BadPsk)
		}
		messages = add_psks(shape.messages, psks)?
		initiator = c.role == Initiator
		# Which keys this side needs: its static one if it sends it (or it's
		# known in advance), the other's if that's known in advance.
		my_index_parity = if initiator 0 else 1
		mine = List.keep_if(List.map_with_index(messages, |tokens, i| (tokens, i)), |(_, i)| i % 2 == my_index_parity)
		sends_static = List.any(mine, |(tokens, _)| List.contains(tokens, S))
		my_pre = if initiator shape.initiator_pre else shape.responder_pre
		their_pre = if initiator shape.responder_pre else shape.initiator_pre
		s =
			match c.static_key {
				Key(secret) => Key({ secret, public: Cryptography.X25519.public_key!(secret) })
				NoKey => if sends_static or my_pre return Err(MissingKey(Static)) else NoKey
			}
		if their_pre and c.remote_static_key == NoKey {
			return Err(MissingKey(RemoteStatic))
		}
		name = Str.to_utf8(Config.(c).protocol_name())
		h = if List.len(name) <= 32 List.concat(name, List.repeat(0, 32 - List.len(name))) else Crypto.SHA256.hash(name).to_bytes()
		var $sym = mix_hash({ cipher: c.cipher, h, ck: h, k: NoKey, n: 0 }, c.prologue)
		# Pre-messages: the initiator's, then the responder's.
		pre_keys = [(shape.initiator_pre, Initiator), (shape.responder_pre, Responder)]
		for (present, owner) in pre_keys {
			if present {
				public =
					if owner == c.role {
						match s {
							Key(pair) => pair.public.to_bytes()
							NoKey => []
						}
					} else {
						match c.remote_static_key {
							Key(key) => key.to_bytes()
							NoKey => []
						}
					}
				$sym = mix_hash($sym, public)
			}
		}
		Ok(Handshake.({
			role: c.role,
			sym: $sym,
			s,
			e: NoKey,
			rs: c.remote_static_key,
			re: NoKey,
			psks: List.map(psks, |psk| psk.key),
			psk_mode: !List.is_empty(psks),
			messages,
			index: 0,
			ephemeral: c.ephemeral,
		}))
	}

	## An encrypted stream after a handshake: Noise transport messages over a
	## TCP or Unix stream, each a 2-byte big-endian length and then the
	## ciphertext (as libp2p-noise frames them). It has the same methods as
	## `Tcp.Stream`, so code written against those (like `Framing`) works with
	## it, and one task can read while another writes.
	##
	## A write longer than a Noise message holds (65,519 bytes of plaintext)
	## is sent as several. Noise has no closing message, so the end of the
	## stream can't be told from a connection an attacker cut between
	## messages: a protocol that must know it got everything has to say so
	## itself (a length up front, or a last message).
	##
	## Not yet supported: `Select` arms and `Pipe.copy_both!` / `copy_to!`
	## on it. Every operation fails with `NoiseErr(IOErr)`.
	Stream :: Host.Socket.{

		## Read up to `max` bytes of plaintext; an empty list once the other
		## side has closed the connection. Fails with `NoiseErr(Other(...))` if
		## a message doesn't authenticate (tampered with, or out of order).
		read! : Stream, U64 => Try(List(U8), [NoiseErr(IOErr)])
		read! = |Stream.(stream), max| noise_err(Host.socket_read!(stream, max))

		## Like `read!`, reusing `buffer`'s memory (see `Tcp.Stream.read_into!`).
		read_into! : Stream, List(U8), U64 => Try(List(U8), [NoiseErr(IOErr)])
		read_into! = |Stream.(stream), buffer, max| noise_err(Host.socket_read_into!(stream, buffer, max))

		## Like `read!`, adding to the end of `buffer` (see
		## `Tcp.Stream.read_append!`). `Framing` reads this way.
		read_append! : Stream, List(U8), U64 => Try(List(U8), [NoiseErr(IOErr)])
		read_append! = |Stream.(stream), buffer, max| noise_err(Host.socket_read_append!(stream, buffer, max))

		## Encrypt and send all of `bytes`.
		write! : Stream, List(U8) => Try({}, [NoiseErr(IOErr)])
		write! = |Stream.(stream), bytes| noise_err(Host.socket_write!(stream, bytes))

		write_str! : Stream, Str => Try({}, [NoiseErr(IOErr)])
		write_str! = |stream, text| stream.write!(Str.to_utf8(text))

		## Shut down one or both directions of the connection underneath.
		shutdown! : Stream, [Read, Write, Both] => Try({}, [NoiseErr(IOErr)])
		shutdown! = |Stream.(stream), how| {
			code =
				match how {
					Read => 0
					Write => 1
					Both => 2
				}
			noise_err(Host.socket_shutdown!(stream, code))
		}

		## Close the connection now.
		close! : Stream => {}
		close! = |Stream.(stream)| {
			_ = Host.socket_shutdown!(stream, 2)
			{}
		}

		## Give up on the connection partway through (see `Tcp.Stream.abort!`).
		abort! : Stream => {}
		abort! = |Stream.(stream)| Host.socket_abort!(stream)

		set_read_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [NoiseErr(IOErr)])
		set_read_timeout! = |Stream.(stream), timeout| noise_err(Host.socket_set_timeout!(stream, 0, timeout_ms(timeout)))

		set_write_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [NoiseErr(IOErr)])
		set_write_timeout! = |Stream.(stream), timeout| noise_err(Host.socket_set_timeout!(stream, 1, timeout_ms(timeout)))

		## For a stream over TCP; see `Tcp.Stream.set_nodelay!`.
		set_nodelay! : Stream, Bool => Try({}, [NoiseErr(IOErr)])
		set_nodelay! = |Stream.(stream), enabled| noise_err(Host.tcp_set_nodelay!(stream, enabled))

		local_addr! : Stream => Try(Str, [NoiseErr(IOErr)])
		local_addr! = |Stream.(stream)| noise_err(Host.socket_local_addr!(stream))

		peer_addr! : Stream => Try(Str, [NoiseErr(IOErr)])
		peer_addr! = |Stream.(stream)| noise_err(Host.socket_peer_addr!(stream))

		## What a read reports when the read timeout passes (for `Framing`).
		timeout_error : Stream -> [NoiseErr(IOErr)]
		timeout_error = |_| NoiseErr(TimedOut)
	}

	## Run a handshake over `stream` (a TCP or Unix stream), and switch it to
	## Noise transport messages: the `Noise.Stream` to use from then on (don't
	## use `stream` itself again), the handshake hash, the other side's static
	## key (if the pattern sends or knows one), and the payloads the other
	## side sent in its handshake messages.
	##
	## `payloads` are this side's handshake payloads, in order, one per
	## message it writes (missing ones are empty). Each handshake message goes
	## as a 2-byte big-endian length and then the message, as libp2p-noise
	## sends them. A handshake message that doesn't authenticate (different
	## keys or prologue, tampering) fails with `Invalid`; the stream ending
	## first, with `HandshakeEnded`; the stream failing, with `StreamErr` and
	## its error (`StreamErr(TcpErr(ConnectionReset))`, say).
	##
	## Reads wait under the stream's own read timeout: set one, since the
	## other side could otherwise hold the handshake open indefinitely.
	handshake! : s, Config, List(List(U8)) => Try(
			{ stream : Stream, handshake_hash : List(U8), remote_static_key : [NoKey, Key(Cryptography.X25519.PublicKey)], payloads : List(List(U8)) },
			_,
		)
		where [
			s.read! : s, U64 => Try(List(U8), e),
			s.write! : s, List(U8) => Try({}, e),
			s.socket : s -> Host.Socket,
		]
	handshake! = |stream, settings, payloads| {
		var $handshake = start!(settings)?
		var $mine = payloads
		var $received = []
		while !$handshake.is_finished() {
			if $handshake.is_my_turn() {
				(payload, rest) =
					match $mine {
						[first, .. as others] => (first, others)
						[] => ([], [])
					}
				$mine = rest
				(message, next) = $handshake.write_message!(payload)?
				# write_message! keeps messages within 65,535 bytes.
				match stream.write!(List.concat(Bytes.u16_be(List.len(message).to_u16_wrap()), message)) {
					Ok({}) => {}
					Err(err) => return Err(StreamErr(err))
				}
				$handshake = next
			} else {
				# Exactly the length, then exactly the message: no further, since
				# what follows is for the Noise.Stream.
				var $header = []
				while List.len($header) < 2 {
					match stream.read!(2 - List.len($header)) {
						Ok([]) => return Err(HandshakeEnded)
						Ok(bytes) => {
							$header = List.concat($header, bytes)
						}
						Err(err) => return Err(StreamErr(err))
					}
				}
				length = (Bytes.u16_be_at($header, 0) ?? 0).to_u64()
				var $message = []
				while List.len($message) < length {
					match stream.read!(length - List.len($message)) {
						Ok([]) => return Err(HandshakeEnded)
						Ok(bytes) => {
							$message = List.concat($message, bytes)
						}
						Err(err) => return Err(StreamErr(err))
					}
				}
				message = $message
				(payload, next) = $handshake.read_message!(message)?
				$received = List.append($received, payload)
				$handshake = next
			}
		}
		{ send, receive, handshake_hash, remote_static_key } = $handshake.finish()?
		noise_stream = wrap!(stream, send, receive)?
		Ok({ stream: noise_stream, handshake_hash, remote_static_key, payloads: $received })
	}

	## Switch `stream` (a TCP or Unix stream) to Noise transport messages with
	## these cipher states, from a handshake done another way (with
	## `Handshake`'s own methods). Don't use `stream` itself afterwards.
	wrap! : s, CipherState, CipherState => Try(Stream, [NoiseErr(IOErr)]) where [s.socket : s -> Host.Socket]
	wrap! = |stream, send, receive| {
		sending = send.parts()
		receiving = receive.parts()
		cipher =
			match sending.cipher {
				ChaChaPoly => 0
				AesGcm => 1
			}
		match Host.noise_wrap!(stream.socket(), cipher, sending.key, sending.nonce, receiving.key, receiving.nonce) {
			Ok(socket) => Ok(Stream.(socket))
			Err(err) => Err(NoiseErr(err))
		}
	}

	# --- Internals ---

	noise_err : Try(ok, IOErr) -> Try(ok, [NoiseErr(IOErr)])
	noise_err = |result|
		match result {
			Ok(value) => Ok(value)
			Err(err) => Err(NoiseErr(err))
		}

	timeout_ms : [NoTimeout, Millis(U64)] -> U64
	timeout_ms = |timeout|
		match timeout {
			NoTimeout => 0
			Millis(ms) => if ms == 0 1 else ms
		}

	Token : [E, S, EE, ES, SE, SS, Psk]

	KeyPair : { secret : Cryptography.X25519.SecretKey, public : Cryptography.X25519.PublicKey }

	## The symmetric state (specification §5.2): chaining key `ck`, hash `h`,
	## and the current key and nonce.
	Symmetric : { cipher : Cipher, h : List(U8), ck : List(U8), k : [NoKey, Key(List(U8))], n : U64 }

	pattern_name : Pattern -> Str
	pattern_name = |pattern|
		match pattern {
			N => "N"
			K => "K"
			X => "X"
			NN => "NN"
			NK => "NK"
			NX => "NX"
			KN => "KN"
			KK => "KK"
			KX => "KX"
			XN => "XN"
			XK => "XK"
			XX => "XX"
			IN => "IN"
			IK => "IK"
			IX => "IX"
		}

	## Pre-messages (whether each side's static key is known in advance) and
	## the message patterns, alternating from the initiator.
	pattern_shape : Pattern -> { initiator_pre : Bool, responder_pre : Bool, messages : List(List(Token)) }
	pattern_shape = |pattern|
		match pattern {
			N => { initiator_pre: False, responder_pre: True, messages: [[E, ES]] }
			K => { initiator_pre: True, responder_pre: True, messages: [[E, ES, SS]] }
			X => { initiator_pre: False, responder_pre: True, messages: [[E, ES, S, SS]] }
			NN => { initiator_pre: False, responder_pre: False, messages: [[E], [E, EE]] }
			NK => { initiator_pre: False, responder_pre: True, messages: [[E, ES], [E, EE]] }
			NX => { initiator_pre: False, responder_pre: False, messages: [[E], [E, EE, S, ES]] }
			KN => { initiator_pre: True, responder_pre: False, messages: [[E], [E, EE, SE]] }
			KK => { initiator_pre: True, responder_pre: True, messages: [[E, ES, SS], [E, EE, SE]] }
			KX => { initiator_pre: True, responder_pre: False, messages: [[E], [E, EE, SE, S, ES]] }
			XN => { initiator_pre: False, responder_pre: False, messages: [[E], [E, EE], [S, SE]] }
			XK => { initiator_pre: False, responder_pre: True, messages: [[E, ES], [E, EE], [S, SE]] }
			XX => { initiator_pre: False, responder_pre: False, messages: [[E], [E, EE, S, ES], [S, SE]] }
			IN => { initiator_pre: False, responder_pre: False, messages: [[E, S], [E, EE, SE]] }
			IK => { initiator_pre: False, responder_pre: True, messages: [[E, ES, S, SS], [E, EE, SE]] }
			IX => { initiator_pre: False, responder_pre: False, messages: [[E, S], [E, EE, SE, S, ES]] }
		}

	sort_psks : List({ position : U64, key : List(U8) }) -> List({ position : U64, key : List(U8) })
	sort_psks = |psks| List.sort_with(psks, |a, b| if a.position < b.position Before else if a.position > b.position After else Same)

	## The message patterns with `psk` tokens added (§9.2): `psk0` at the
	## start of the first message, `pskN` at the end of the Nth.
	add_psks : List(List(Token)), List({ position : U64, key : List(U8) }) -> Try(List(List(Token)), [BadPsk])
	add_psks = |messages, psks| {
		var $messages = messages
		var $last = U64.highest
		for psk in psks {
			if psk.position == $last or psk.position > List.len(messages) {
				return Err(BadPsk)
			}
			$last = psk.position
			$messages =
				if psk.position == 0 {
					List.map_with_index($messages, |tokens, i| if i == 0 List.prepend(tokens, Psk) else tokens)
				} else {
					List.map_with_index($messages, |tokens, i| if i == psk.position - 1 List.append(tokens, Psk) else tokens)
				}
		}
		Ok($messages)
	}

	my_turn = |h| (h.index % 2 == 0) == (h.role == Initiator)

	next_tokens = |h|
		match List.get(h.messages, h.index) {
			Err(_) => Err(Finished)
			Ok(tokens) => if my_turn(h) Ok(tokens) else Err(NotMyTurn)
		}

	next_tokens_to_read = |h|
		match List.get(h.messages, h.index) {
			Err(_) => Err(Finished)
			Ok(tokens) => if my_turn(h) Err(NotMyTurn) else Ok(tokens)
		}

	# `start!` adds a `psk` token per pre-shared key, so there's always one.
	use_psk = |h|
		match h.psks {
			[psk, .. as rest] => { ..h, psks: rest, sym: mix_key_and_hash(h.sym, psk) }
			[] => crash "Noise: more psk tokens than pre-shared keys"
		}

	## The Diffie-Hellman result a token calls for, from this side's view.
	dh! = |h, token| {
		initiator = h.role == Initiator
		(mine, theirs) =
			match token {
				EE => (h.e, h.re)
				ES => if initiator (h.e, h.rs) else (h.s, h.re)
				SE => if initiator (h.s, h.re) else (h.e, h.rs)
				_ => (h.s, h.rs)
			}
		# The pattern gives both keys before any token uses them, and `start!`
		# checks for the static ones.
		match (mine, theirs) {
			(Key(pair), Key(public)) => Cryptography.X25519.shared_secret!(pair.secret, public)
			_ => crash "Noise: a key a token needs isn't there"
		}
	}

	public_key = |bytes|
		match Cryptography.X25519.public_key_from_bytes(bytes) {
			Ok(key) => key
			Err(_) => crash "Noise: a 32-byte public key was rejected"
		}

	has_key = |sym|
		match sym.k {
			Key(_) => True
			NoKey => False
		}

	mix_hash : Symmetric, List(U8) -> Symmetric
	mix_hash = |sym, data| { ..sym, h: Crypto.SHA256.Hasher.empty().write(sym.h).write(data).finish().to_bytes() }

	mix_key : Symmetric, List(U8) -> Symmetric
	mix_key = |sym, input| {
		(ck, key) = hkdf2(sym.ck, input)
		{ ..sym, ck, k: Key(key), n: 0 }
	}

	mix_key_and_hash : Symmetric, List(U8) -> Symmetric
	mix_key_and_hash = |sym, input| {
		temp = Cryptography.HmacSha256.tag(sym.ck, input)
		ck = Cryptography.HmacSha256.tag(temp, [1])
		temp_h = Cryptography.HmacSha256.tag(temp, List.append(ck, 2))
		key = Cryptography.HmacSha256.tag(temp, List.append(temp_h, 3))
		mixed = mix_hash({ ..sym, ck }, temp_h)
		{ ..mixed, k: Key(key), n: 0 }
	}

	## Noise's HKDF with two outputs (§4.3).
	hkdf2 : List(U8), List(U8) -> (List(U8), List(U8))
	hkdf2 = |chaining_key, input| {
		temp = Cryptography.HmacSha256.tag(chaining_key, input)
		first = Cryptography.HmacSha256.tag(temp, [1])
		(first, Cryptography.HmacSha256.tag(temp, List.append(first, 2)))
	}

	encrypt_and_hash! = |sym, plaintext|
		match sym.k {
			NoKey => Ok((plaintext, mix_hash(sym, plaintext)))
			Key(key) =>
				if sym.n == U64.highest {
					Err(NonceExhausted)
				} else {
					sealed = seal!(sym.cipher, key, sym.n, sym.h, plaintext)
					Ok((sealed, mix_hash({ ..sym, n: sym.n + 1 }, sealed)))
				}
		}

	decrypt_and_hash! = |sym, data|
		match sym.k {
			NoKey => Ok((data, mix_hash(sym, data)))
			Key(key) =>
				if sym.n == U64.highest {
					Err(NonceExhausted)
				} else {
					plaintext = open!(sym.cipher, key, sym.n, sym.h, data)?
					Ok((plaintext, mix_hash({ ..sym, n: sym.n + 1 }, data)))
				}
		}

	## The 12-byte nonce for counter `n` (§12.3, §12.4): 4 zero bytes, then
	## the counter, little-endian for ChaChaPoly and big-endian for AESGCM.
	nonce_bytes = |cipher, n|
		match cipher {
			ChaChaPoly => List.concat([0, 0, 0, 0], Bytes.u64_le(n))
			AesGcm => List.concat([0, 0, 0, 0], Bytes.u64_be(n))
		}

	seal! = |cipher, key, n, associated_data, plaintext|
		match cipher {
			ChaChaPoly =>
				match (Cryptography.ChaChaPoly.key_from_bytes(key), Cryptography.ChaChaPoly.nonce_from_bytes(nonce_bytes(cipher, n))) {
					(Ok(k), Ok(nonce)) => Cryptography.ChaChaPoly.seal!(k, nonce, associated_data, plaintext)
					_ => crash "Noise: a 32-byte key or 12-byte nonce was rejected"
				}
			AesGcm =>
				match (Cryptography.AesGcm.key_from_bytes(key), Cryptography.AesGcm.nonce_from_bytes(nonce_bytes(cipher, n))) {
					(Ok(k), Ok(nonce)) => Cryptography.AesGcm.seal!(k, nonce, associated_data, plaintext)
					_ => crash "Noise: a 32-byte key or 12-byte nonce was rejected"
				}
		}

	open! = |cipher, key, n, associated_data, sealed|
		match cipher {
			ChaChaPoly =>
				match (Cryptography.ChaChaPoly.key_from_bytes(key), Cryptography.ChaChaPoly.nonce_from_bytes(nonce_bytes(cipher, n))) {
					(Ok(k), Ok(nonce)) => Cryptography.ChaChaPoly.open!(k, nonce, associated_data, sealed)
					_ => crash "Noise: a 32-byte key or 12-byte nonce was rejected"
				}
			AesGcm =>
				match (Cryptography.AesGcm.key_from_bytes(key), Cryptography.AesGcm.nonce_from_bytes(nonce_bytes(cipher, n))) {
					(Ok(k), Ok(nonce)) => Cryptography.AesGcm.open!(k, nonce, associated_data, sealed)
					_ => crash "Noise: a 32-byte key or 12-byte nonce was rejected"
				}
		}
}
