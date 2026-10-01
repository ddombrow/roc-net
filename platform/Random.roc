import Bytes
import Host

## Cryptographically secure random numbers (from the same generator the
## platform's TLS uses, seeded by the operating system), suitable for IDs,
## nonces, keys, and anything an attacker must not be able to predict.
##
## If the generator fails, the program stops with an error message: nothing
## random could be trusted after that.
Random := [].{

	## `count` random bytes, at most 16 MiB (16,777,216). Asking for more
	## fails with `TooManyBytes` before anything is allocated, and with
	## `OutOfMemory` if the bytes can't be allocated. Keys, nonces and IDs
	## need far less, so check a count that comes from untrusted input.
	##
	## ```roc
	## key = Random.bytes!(32)?
	## ```
	bytes! : U64 => Try(List(U8), [TooManyBytes({ requested : U64, max : U64 }), OutOfMemory])
	bytes! = |count| {
		if count > max_bytes {
			return Err(TooManyBytes({ requested: count, max: max_bytes }))
		}
		match Host.random_bytes!(count) {
			Bytes(bytes) => Ok(bytes)
			OutOfMemory => Err(OutOfMemory)
		}
	}

	## The most `bytes!` gives at once: 16 MiB.
	max_bytes : U64
	max_bytes = 16 * 1024 * 1024

	u8! : () => U8
	u8! = || {
		match few!(1) {
			[a] => a
			_ => 0
		}
	}

	u16! : () => U16
	u16! = || u64!().to_u16_wrap()

	u32! : () => U32
	u32! = || u64!().to_u32_wrap()

	u64! : () => U64
	u64! = || {
		match Bytes.take_u64_be(few!(8)) {
			Ok((n, _)) => n
			Err(TooShort) => 0
		}
	}

	## A random number from `low` to `high`, including both, with every value
	## equally likely. Returns `low` if `high` is less than `low`.
	between! : U64, U64 => U64
	between! = |low, high| {
		if high <= low {
			return low
		}
		if high - low == U64.highest {
			# low..high covers every U64 value, so the count of values
			# (high - low + 1) wouldn't fit in a U64.
			return u64!()
		}
		range = high - low + 1
		# Taking `n % range` of a random U64 would make the smallest values
		# slightly more likely whenever `range` doesn't divide 2^64. Values
		# below `threshold` are exactly that surplus, so draw again.
		threshold = (U64.highest - range + 1) % range
		var $n = u64!()
		while $n < threshold {
			$n = u64!()
		}
		low + $n % range
	}

	## A handful of bytes, for the fixed-size functions above: far under the
	## limit, and too few for running out of memory to be the likely end.
	few! : U64 => List(U8)
	few! = |count|
		match bytes!(count) {
			Ok(bytes) => bytes
			Err(err) => crash "Random: couldn't get ${count.to_str()} random bytes: ${Str.inspect(err)}"
		}
}
