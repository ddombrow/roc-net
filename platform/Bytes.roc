## Encode and decode integers as bytes, for binary protocols.
##
## Big-endian ("network byte order", `_be`) puts the most significant byte
## first, which is what most network protocols use. Little-endian (`_le`) puts
## it last.
##
## The `take_` functions decode from the start of a byte list and return the
## value together with the remaining bytes, so a message can be decoded field
## by field:
##
## ```roc
## (id, rest1) = Bytes.take_u16_be(packet)?
## (flags, rest2) = Bytes.take_u16_be(rest1)?
## ```
##
## They fail with `TooShort` if there aren't enough bytes left.
Bytes := [].{

	## Encode as 2 big-endian bytes.
	u16_be : U16 -> List(U8)
	u16_be = |n| [(n // 256).to_u8_wrap(), (n % 256).to_u8_wrap()]

	## Encode as 4 big-endian bytes.
	u32_be : U32 -> List(U8)
	u32_be = |n| [
		(n // 16777216).to_u8_wrap(),
		(n // 65536 % 256).to_u8_wrap(),
		(n // 256 % 256).to_u8_wrap(),
		(n % 256).to_u8_wrap(),
	]

	## Encode as 8 big-endian bytes.
	u64_be : U64 -> List(U8)
	u64_be = |n| List.concat(u32_be((n // 4294967296).to_u32_wrap()), u32_be((n % 4294967296).to_u32_wrap()))

	## Encode as 2 little-endian bytes.
	u16_le : U16 -> List(U8)
	u16_le = |n| List.rev(u16_be(n))

	## Encode as 4 little-endian bytes.
	u32_le : U32 -> List(U8)
	u32_le = |n| List.rev(u32_be(n))

	## Encode as 8 little-endian bytes.
	u64_le : U64 -> List(U8)
	u64_le = |n| List.rev(u64_be(n))

	## Take the first `count` bytes, returning them and the bytes after them.
	take : List(U8), U64 -> Try((List(U8), List(U8)), [TooShort])
	take = |bytes, count|
		if List.len(bytes) < count {
			Err(TooShort)
		} else {
			split = List.split_at(bytes, count)
			Ok((split.before, split.others))
		}

	## Decode a `U8` from the start of `bytes`.
	take_u8 : List(U8) -> Try((U8, List(U8)), [TooShort])
	take_u8 = |bytes|
		match bytes {
			[a, .. as rest] => Ok((a, rest))
			_ => Err(TooShort)
		}

	## Decode a big-endian `U16` from the start of `bytes`.
	take_u16_be : List(U8) -> Try((U16, List(U8)), [TooShort])
	take_u16_be = |bytes|
		match bytes {
			[a, b, .. as rest] => Ok((a.to_u16() * 256 + b.to_u16(), rest))
			_ => Err(TooShort)
		}

	## Decode a big-endian `U32` from the start of `bytes`.
	take_u32_be : List(U8) -> Try((U32, List(U8)), [TooShort])
	take_u32_be = |bytes|
		match bytes {
			[a, b, c, d, .. as rest] =>
				Ok((a.to_u32() * 16777216 + b.to_u32() * 65536 + c.to_u32() * 256 + d.to_u32(), rest))
			_ => Err(TooShort)
		}

	## Decode a big-endian `U64` from the start of `bytes`.
	take_u64_be : List(U8) -> Try((U64, List(U8)), [TooShort])
	take_u64_be = |bytes| {
		(high, rest1) = take_u32_be(bytes)?
		(low, rest2) = take_u32_be(rest1)?
		Ok((high.to_u64() * 4294967296 + low.to_u64(), rest2))
	}

	## Decode a little-endian `U16` from the start of `bytes`.
	take_u16_le : List(U8) -> Try((U16, List(U8)), [TooShort])
	take_u16_le = |bytes| {
		(field, rest) = take(bytes, 2)?
		(n, _) = take_u16_be(List.rev(field))?
		Ok((n, rest))
	}

	## Decode a little-endian `U32` from the start of `bytes`.
	take_u32_le : List(U8) -> Try((U32, List(U8)), [TooShort])
	take_u32_le = |bytes| {
		(field, rest) = take(bytes, 4)?
		(n, _) = take_u32_be(List.rev(field))?
		Ok((n, rest))
	}

	## Decode a little-endian `U64` from the start of `bytes`.
	take_u64_le : List(U8) -> Try((U64, List(U8)), [TooShort])
	take_u64_le = |bytes| {
		(field, rest) = take(bytes, 8)?
		(n, _) = take_u64_be(List.rev(field))?
		Ok((n, rest))
	}
}
