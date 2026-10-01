import Host

## Cryptographic primitives: key agreement, authenticated encryption,
## signatures, message authentication and key derivation. The building
## blocks of protocols such as `Noise`; for a secure connection, use `Tls`
## or `Noise` rather than assembling these yourself.
##
## ```roc
## import pf.Cryptography as C
##
## alice = C.X25519.generate!({})
## bob = C.X25519.generate!({})
## # Each side computes the same secret from its own secret key and the
## # other's public key.
## shared = C.X25519.shared_secret!(alice, C.X25519.public_key!(bob))?
## ```
##
## - `X25519`: Diffie-Hellman key agreement (RFC 7748).
## - `ChaChaPoly` and `AesGcm`: authenticated encryption with associated
##   data, ChaCha20-Poly1305 (RFC 8439) and AES-256-GCM.
## - `Ed25519`: signatures (RFC 8032).
## - `HmacSha256` and `HkdfSha256`: message authentication (RFC 2104) and key
##   derivation (RFC 5869).
## - `constant_time_eq!`: comparing secrets without leaking where they differ.
##
## SHA-256 itself is Roc's builtin `Crypto.SHA256`.
##
## Most are backed by AWS-LC (the library `Tls` uses) and so are `!`
## functions, as everything the platform provides must be, though they only
## compute. `HmacSha256` and `HkdfSha256` are written in Roc on the builtin
## SHA-256, and are pure.
##
## Secret keys are opaque: `Str.inspect` shows no key material, and their
## bytes come out only through `to_bytes`, for storing them. Roc doesn't wipe
## memory when it's freed, so secret bytes may linger there until it's
## reused.
Cryptography := [].{

	## X25519 key agreement (RFC 7748): two parties, each with a secret key,
	## derive the same 32-byte shared secret from their own secret key and the
	## other's public key.
	X25519 :: {}.{

		## A 32-byte X25519 secret key.
		SecretKey :: List(U8).{

			## The key's 32 bytes, for storing it. Keep them secret.
			to_bytes : SecretKey -> List(U8)
			to_bytes = |SecretKey.(bytes)| bytes
		}

		## A 32-byte X25519 public key.
		PublicKey :: List(U8).{

			to_bytes : PublicKey -> List(U8)
			to_bytes = |PublicKey.(bytes)| bytes

			is_eq : PublicKey, PublicKey -> Bool
			is_eq = |PublicKey.(a), PublicKey.(b)| a == b
		}

		## A new secret key, from the OS's secure random source.
		generate! : {} => SecretKey
		generate! = |{}| SecretKey.(Host.random_bytes!(32))

		## A secret key from its 32 bytes (as `to_bytes` gave them).
		secret_key_from_bytes : List(U8) -> Try(SecretKey, [WrongLength({ expected : U64, actual : U64 })])
		secret_key_from_bytes = |bytes| check_length(bytes, 32).map_ok(|valid| SecretKey.(valid))

		## A public key from its 32 bytes.
		public_key_from_bytes : List(U8) -> Try(PublicKey, [WrongLength({ expected : U64, actual : U64 })])
		public_key_from_bytes = |bytes| check_length(bytes, 32).map_ok(|valid| PublicKey.(valid))

		## The public key to give the other party.
		public_key! : SecretKey => PublicKey
		public_key! = |SecretKey.(secret)| PublicKey.(Host.x25519_public_key!(secret))

		## The 32-byte secret shared with the owner of `public`. Fails with
		## `LowOrderPoint` for a public key that would make it all zeros (a
		## key chosen to force a known secret), as RFC 7748 says to check.
		## Feed it through a key derivation (`HkdfSha256`) before use.
		shared_secret! : SecretKey, PublicKey => Try(List(U8), [LowOrderPoint])
		shared_secret! = |SecretKey.(secret), PublicKey.(public)|
			match Host.x25519_shared!(secret, public) {
				Shared(shared) => Ok(shared)
				LowOrder => Err(LowOrderPoint)
			}
	}

	## ChaCha20-Poly1305 (RFC 8439): authenticated encryption with a 32-byte
	## key and a 12-byte nonce. `seal!` encrypts and appends a 16-byte tag;
	## `open!` checks the tag and decrypts, or fails if anything (the
	## ciphertext, the associated data, the nonce, the key) doesn't match.
	##
	## Never seal two messages with the same key and nonce: that reveals both.
	## A counter per key is the usual nonce (as `Noise` uses).
	ChaChaPoly :: {}.{

		## A 32-byte key.
		Key :: List(U8).{

			to_bytes : Key -> List(U8)
			to_bytes = |Key.(bytes)| bytes
		}

		## A 12-byte nonce.
		Nonce :: List(U8).{

			to_bytes : Nonce -> List(U8)
			to_bytes = |Nonce.(bytes)| bytes
		}

		## A new key, from the OS's secure random source.
		generate! : {} => Key
		generate! = |{}| Key.(Host.random_bytes!(32))

		key_from_bytes : List(U8) -> Try(Key, [WrongLength({ expected : U64, actual : U64 })])
		key_from_bytes = |bytes| check_length(bytes, 32).map_ok(|valid| Key.(valid))

		nonce_from_bytes : List(U8) -> Try(Nonce, [WrongLength({ expected : U64, actual : U64 })])
		nonce_from_bytes = |bytes| check_length(bytes, 12).map_ok(|valid| Nonce.(valid))

		## `plaintext`, encrypted, with a 16-byte tag appended that also covers
		## `associated_data` (sent alongside, unencrypted, or known to both
		## sides).
		seal! : Key, Nonce, List(U8), List(U8) => List(U8)
		seal! = |Key.(key), Nonce.(nonce), associated_data, plaintext| Host.aead_seal!(0, key, nonce, associated_data, plaintext)

		## The plaintext, if `sealed` came from `seal!` with this key, nonce and
		## associated data; `Err(Invalid)` if anything differs.
		open! : Key, Nonce, List(U8), List(U8) => Try(List(U8), [Invalid])
		open! = |Key.(key), Nonce.(nonce), associated_data, sealed|
			match Host.aead_open!(0, key, nonce, associated_data, sealed) {
				Opened(plaintext) => Ok(plaintext)
				Invalid => Err(Invalid)
			}
	}

	## AES-256-GCM: authenticated encryption, as `ChaChaPoly` but with AES
	## (fast where the CPU has AES instructions). The same key and nonce sizes
	## and rules.
	AesGcm :: {}.{

		## A 32-byte key.
		Key :: List(U8).{

			to_bytes : Key -> List(U8)
			to_bytes = |Key.(bytes)| bytes
		}

		## A 12-byte nonce.
		Nonce :: List(U8).{

			to_bytes : Nonce -> List(U8)
			to_bytes = |Nonce.(bytes)| bytes
		}

		generate! : {} => Key
		generate! = |{}| Key.(Host.random_bytes!(32))

		key_from_bytes : List(U8) -> Try(Key, [WrongLength({ expected : U64, actual : U64 })])
		key_from_bytes = |bytes| check_length(bytes, 32).map_ok(|valid| Key.(valid))

		nonce_from_bytes : List(U8) -> Try(Nonce, [WrongLength({ expected : U64, actual : U64 })])
		nonce_from_bytes = |bytes| check_length(bytes, 12).map_ok(|valid| Nonce.(valid))

		seal! : Key, Nonce, List(U8), List(U8) => List(U8)
		seal! = |Key.(key), Nonce.(nonce), associated_data, plaintext| Host.aead_seal!(1, key, nonce, associated_data, plaintext)

		open! : Key, Nonce, List(U8), List(U8) => Try(List(U8), [Invalid])
		open! = |Key.(key), Nonce.(nonce), associated_data, sealed|
			match Host.aead_open!(1, key, nonce, associated_data, sealed) {
				Opened(plaintext) => Ok(plaintext)
				Invalid => Err(Invalid)
			}
	}

	## Ed25519 signatures (RFC 8032): a secret key signs messages; anyone with
	## the public key can check the signatures.
	Ed25519 :: {}.{

		## A 32-byte Ed25519 secret key (the seed RFC 8032 derives the signing
		## key from).
		SecretKey :: List(U8).{

			## The key's 32 bytes, for storing it. Keep them secret.
			to_bytes : SecretKey -> List(U8)
			to_bytes = |SecretKey.(bytes)| bytes
		}

		## A 32-byte Ed25519 public key.
		PublicKey :: List(U8).{

			to_bytes : PublicKey -> List(U8)
			to_bytes = |PublicKey.(bytes)| bytes

			is_eq : PublicKey, PublicKey -> Bool
			is_eq = |PublicKey.(a), PublicKey.(b)| a == b
		}

		## A new secret key, from the OS's secure random source.
		generate! : {} => SecretKey
		generate! = |{}| SecretKey.(Host.random_bytes!(32))

		secret_key_from_bytes : List(U8) -> Try(SecretKey, [WrongLength({ expected : U64, actual : U64 })])
		secret_key_from_bytes = |bytes| check_length(bytes, 32).map_ok(|valid| SecretKey.(valid))

		public_key_from_bytes : List(U8) -> Try(PublicKey, [WrongLength({ expected : U64, actual : U64 })])
		public_key_from_bytes = |bytes| check_length(bytes, 32).map_ok(|valid| PublicKey.(valid))

		public_key! : SecretKey => PublicKey
		public_key! = |SecretKey.(secret)| PublicKey.(Host.ed25519_public_key!(secret))

		## The 64-byte signature of `message`.
		sign! : SecretKey, List(U8) => List(U8)
		sign! = |SecretKey.(secret), message| Host.ed25519_sign!(secret, message)

		## Whether `signature` is a valid signature of `message` by `public`'s
		## owner.
		verify! : PublicKey, List(U8), List(U8) => Bool
		verify! = |PublicKey.(public), message, signature| Host.ed25519_verify!(public, message, signature)
	}

	## HMAC-SHA-256 (RFC 2104): a 32-byte tag proving a message came from
	## someone with the key, unchanged. Check a tag with `constant_time_eq!`,
	## not `==`.
	HmacSha256 :: {}.{

		## The 32-byte tag of `message` under `key` (any length; keys longer
		## than 64 bytes are hashed first, as HMAC specifies).
		tag : List(U8), List(U8) -> List(U8)
		tag = |key, message| {
			block = 64
			short_key = if List.len(key) > block Crypto.SHA256.hash(key).to_bytes() else key
			padded = List.concat(short_key, List.repeat(0, block - List.len(short_key)))
			inner_pad = List.map(padded, |b| U8.bitwise_xor(b, 0x36))
			outer_pad = List.map(padded, |b| U8.bitwise_xor(b, 0x5c))
			inner = Crypto.SHA256.Hasher.empty().write(inner_pad).write(message).finish().to_bytes()
			Crypto.SHA256.Hasher.empty().write(outer_pad).write(inner).finish().to_bytes()
		}
	}

	## HKDF with SHA-256 (RFC 5869): derive keys from a secret (such as an
	## X25519 shared secret). `extract` concentrates the input's randomness
	## into a 32-byte pseudorandom key; `expand` stretches that into as many
	## bytes as needed, different for each `info`.
	HkdfSha256 :: {}.{

		## A 32-byte pseudorandom key from `input`, with an optional `salt`
		## (empty for none, which HKDF treats as 32 zero bytes).
		extract : List(U8), List(U8) -> List(U8)
		extract = |salt, input| HmacSha256.tag(salt, input)

		## `length` bytes (at most 8,160) from `prk` (as `extract` made it),
		## specific to `info`.
		expand : List(U8), List(U8), U64 -> Try(List(U8), [TooLong])
		expand = |prk, info, length| {
			if length > 255 * 32 {
				return Err(TooLong)
			}
			var $out = []
			var $previous = []
			var $counter = 1
			while List.len($out) < length {
				$previous = HmacSha256.tag(prk, List.concat(List.concat($previous, info), [$counter]))
				$out = List.concat($out, $previous)
				$counter = $counter + 1
			}
			Ok(List.take_first($out, length))
		}

		## `extract` then `expand`: `length` bytes derived from `input`.
		derive : { salt : List(U8), input : List(U8), info : List(U8), length : U64 } -> Try(List(U8), [TooLong])
		derive = |{ salt, input, info, length }| expand(extract(salt, input), info, length)
	}

	## Whether `a` and `b` are equal, taking a time that depends only on their
	## lengths, not on where they first differ: for comparing tags, MACs and
	## other secrets, where `==`'s early exit could leak them.
	constant_time_eq! : List(U8), List(U8) => Bool
	constant_time_eq! = |a, b| Host.constant_time_eq!(a, b)

	check_length : List(U8), U64 -> Try(List(U8), [WrongLength({ expected : U64, actual : U64 })])
	check_length = |bytes, expected|
		if List.len(bytes) == expected {
			Ok(bytes)
		} else {
			Err(WrongLength({ expected, actual: List.len(bytes) }))
		}
}
