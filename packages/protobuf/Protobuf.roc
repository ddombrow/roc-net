## Protocol Buffers' wire format: encoding and decoding messages, without a
## schema (https://protobuf.dev/programming-guides/encoding/).
##
## A message is a list of fields, each a field number and a value. A
## schema is code on top: one function to build a message's fields, one to
## read them back, written by hand or generated from a `.proto` file.
##
## ```roc
## # message Point { int32 x = 1; int32 y = 2; string label = 3; }
## encode_point = |p|
##     Protobuf.encode([(1, Protobuf.int32(p.x)), (2, Protobuf.int32(p.y)), (3, Protobuf.string(p.label))])
##
## decode_point = |bytes| {
##     fields = Protobuf.decode(bytes)?
##     x = Protobuf.get(fields, 1, Protobuf.as_int32) ?? 0
##     y = Protobuf.get(fields, 2, Protobuf.as_int32) ?? 0
##     label = Protobuf.get(fields, 3, Protobuf.as_string) ?? ""
##     Ok({ x, y, label })
## }
## ```
##
## Proto3 leaves out fields at their default values (0, "", false, empty),
## and readers treat a missing field as its default, hence the `?? 0` above.
## Fields can arrive in any order; for a scalar field sent more than once,
## the last one counts (`last`), and a repeated field collects every one
## (`repeated`, which also accepts packed and unpacked forms alike). Unknown
## field numbers are kept in `decode`'s result, so a reader can ignore them,
## as protobuf requires.
##
## Groups (wire types 3 and 4, deprecated since proto2) aren't supported:
## `decode` fails with `BadWireType` on them.
Protobuf := [].{

	## A field's value as the wire format carries it. Which protobuf type it
	## stands for is the schema's business: a `Varint` may be an `int32`, a
	## `bool` or an enum; `Bytes` a string, bytes, or an embedded message.
	Value : [Varint(U64), Fixed64(U64), Fixed32(U32), Bytes(List(U8))]

	## Encode `fields`, in the order given.
	encode : List((U64, Value)) -> List(U8)
	encode = |fields|
		List.fold(fields, [], |out, (number, value)|
			match value {
				Varint(n) => List.concat(List.concat(out, varint(number * 8)), varint(n))
				Fixed64(n) => List.concat(List.concat(out, varint(number * 8 + 1)), little_endian(n, 8))
				Bytes(payload) => List.concat(List.concat(List.concat(out, varint(number * 8 + 2)), varint(List.len(payload))), payload)
				Fixed32(n) => List.concat(List.concat(out, varint(number * 8 + 5)), little_endian(n.to_u64(), 4))
			})

	## A message's fields, in the order they appear. Fails with `Truncated`
	## if the message stops partway through a field, `Overlong` for a varint
	## longer than ten bytes (or with more than 64 bits), `BadWireType` for
	## wire types protobuf doesn't define (and groups), and `BadFieldNumber`
	## for field number 0.
	decode : List(U8) -> Try(List((U64, Value)), [Truncated, Overlong, BadWireType(U64), BadFieldNumber(U64)])
	decode = |data| {
		var $at = 0
		var $fields = []
		while $at < List.len(data) {
			(key, after_key) = read_varint(data, $at)?
			number = key // 8
			if number == 0 {
				return Err(BadFieldNumber(number))
			}
			(value, next) =
				match key % 8 {
					0 => {
						(n, after) = read_varint(data, after_key)?
						(Varint(n), after)
					}
					1 => (Fixed64(read_little_endian(data, after_key, 8)?), after_key + 8)
					2 => {
						(len, after) = read_varint(data, after_key)?
						if len > List.len(data) - after {
							return Err(Truncated)
						}
						(Bytes(List.sublist(data, { start: after, len })), after + len)
					}
					5 => (Fixed32(read_little_endian(data, after_key, 4)?.to_u32_wrap()), after_key + 4)
					other => return Err(BadWireType(other))
				}
			$fields = List.append($fields, (number, value))
			$at = next
		}
		Ok($fields)
	}

	## The last value for field `number`, as protobuf reads a scalar field
	## sent more than once; `Err(Missing)` if there's none (so the reader uses
	## the field's default).
	last : List((U64, Value)), U64 -> Try(Value, [Missing])
	last = |fields, number|
		List.fold(fields, Err(Missing), |found, (n, value)| if n == number Ok(value) else found)

	## Field `number`'s value read as a protobuf type, with one of the
	## `as_` functions: `Protobuf.get(fields, 1, Protobuf.as_int32)`. Fails
	## with `Missing` if the message doesn't have it (so the reader uses the
	## field's default, often with `??`), or `Unreadable` with the reader's
	## error if it can't be read as that type.
	get : List((U64, Value)), U64, (Value -> Try(a, e)) -> Try(a, [Missing, Unreadable(e)])
	get = |fields, number, read|
		match last(fields, number) {
			Err(Missing) => Err(Missing)
			Ok(value) =>
				match read(value) {
					Ok(read_value) => Ok(read_value)
					Err(err) => Err(Unreadable(err))
				}
		}

	## Every value for field `number`, in order, for a repeated field of
	## strings, bytes or messages (see `repeated_varints` and friends for
	## numbers, which may also arrive packed).
	repeated : List((U64, Value)), U64 -> List(Value)
	repeated = |fields, number|
		List.fold(fields, [], |found, (n, value)| if n == number List.append(found, value) else found)

	## Every value of a repeated varint field (`int32`, `uint64`, `bool`, enums,
	## ...), whether sent packed, unpacked, or both, in order.
	repeated_varints : List((U64, Value)), U64 -> Try(List(U64), [Truncated, Overlong, WrongType])
	repeated_varints = |fields, number| {
		var $out = []
		for value in repeated(fields, number) {
			match value {
				Varint(n) => {
					$out = List.append($out, n)
				}
				Bytes(packed) => {
					$out = List.concat($out, unpack_varints(packed)?)
				}
				_ => return Err(WrongType)
			}
		}
		Ok($out)
	}

	## Every value of a repeated 8-byte field (`fixed64`, `sfixed64`,
	## `double`), packed or not.
	repeated_fixed64 : List((U64, Value)), U64 -> Try(List(U64), [Truncated, WrongType])
	repeated_fixed64 = |fields, number| {
		var $out = []
		for value in repeated(fields, number) {
			match value {
				Fixed64(n) => {
					$out = List.append($out, n)
				}
				Bytes(packed) => {
					$out = List.concat($out, unpack_fixed(packed, 8)?)
				}
				_ => return Err(WrongType)
			}
		}
		Ok($out)
	}

	## Every value of a repeated 4-byte field (`fixed32`, `sfixed32`,
	## `float`), packed or not.
	repeated_fixed32 : List((U64, Value)), U64 -> Try(List(U32), [Truncated, WrongType])
	repeated_fixed32 = |fields, number| {
		var $out = []
		for value in repeated(fields, number) {
			match value {
				Fixed32(n) => {
					$out = List.append($out, n)
				}
				Bytes(packed) => {
					$out = List.concat($out, List.map(unpack_fixed(packed, 4)?, |n| n.to_u32_wrap()))
				}
				_ => return Err(WrongType)
			}
		}
		Ok($out)
	}

	# --- Building values, one per protobuf type ---

	## `int32`: a negative number takes ten bytes (sign-extended to 64 bits),
	## as the spec requires; use `sint32` for fields often negative.
	int32 : I32 -> Value
	int32 = |n| Varint(n.to_i64().to_u64_wrap())

	int64 : I64 -> Value
	int64 = |n| Varint(n.to_u64_wrap())

	uint32 : U32 -> Value
	uint32 = |n| Varint(n.to_u64())

	uint64 : U64 -> Value
	uint64 = |n| Varint(n)

	## `sint32`: zigzag-encoded, so small negative numbers stay small.
	sint32 : I32 -> Value
	sint32 = |n| Varint(zigzag(n.to_i64()))

	sint64 : I64 -> Value
	sint64 = |n| Varint(zigzag(n))

	bool : Bool -> Value
	bool = |b| Varint(if b 1 else 0)

	## An enum value, by its number.
	enum : I32 -> Value
	enum = |n| int32(n)

	fixed32 : U32 -> Value
	fixed32 = |n| Fixed32(n)

	fixed64 : U64 -> Value
	fixed64 = |n| Fixed64(n)

	sfixed32 : I32 -> Value
	sfixed32 = |n| Fixed32(n.to_u32_wrap())

	sfixed64 : I64 -> Value
	sfixed64 = |n| Fixed64(n.to_u64_wrap())

	float : F32 -> Value
	float = |f| Fixed32(F32.to_bits(f))

	double : F64 -> Value
	double = |f| Fixed64(F64.to_bits(f))

	string : Str -> Value
	string = |s| Bytes(Str.to_utf8(s))

	bytes : List(U8) -> Value
	bytes = |b| Bytes(b)

	## An embedded message.
	message : List((U64, Value)) -> Value
	message = |fields| Bytes(encode(fields))

	## A packed repeated field of numbers (proto3's default for repeated
	## scalars): their encodings one after another, in one `Bytes`. All must
	## be `Varint`s, or all `Fixed32`, or all `Fixed64`; strings and messages
	## are never packed (give each its own field instead).
	packed : List(Value) -> Value
	packed = |values|
		Bytes(List.fold(values, [], |out, value|
			match value {
				Varint(n) => List.concat(out, varint(n))
				Fixed64(n) => List.concat(out, little_endian(n, 8))
				Fixed32(n) => List.concat(out, little_endian(n.to_u64(), 4))
				Bytes(b) => List.concat(out, b)
			}))

	# --- Reading values, one per protobuf type ---

	## `int32` (and enums): the low 32 bits, as protobuf readers take them.
	as_int32 : Value -> Try(I32, [WrongType])
	as_int32 = |value| as_varint(value).map_ok(|n| n.to_u32_wrap().to_i32_wrap())

	as_int64 : Value -> Try(I64, [WrongType])
	as_int64 = |value| as_varint(value).map_ok(|n| n.to_i64_wrap())

	as_uint32 : Value -> Try(U32, [WrongType])
	as_uint32 = |value| as_varint(value).map_ok(|n| n.to_u32_wrap())

	as_uint64 : Value -> Try(U64, [WrongType])
	as_uint64 = |value| as_varint(value)

	as_sint32 : Value -> Try(I32, [WrongType])
	as_sint32 = |value| as_varint(value).map_ok(|n| unzigzag(n).to_i32_wrap())

	as_sint64 : Value -> Try(I64, [WrongType])
	as_sint64 = |value| as_varint(value).map_ok(unzigzag)

	as_bool : Value -> Try(Bool, [WrongType])
	as_bool = |value| as_varint(value).map_ok(|n| n != 0)

	as_fixed32 : Value -> Try(U32, [WrongType])
	as_fixed32 = |value|
		match value {
			Fixed32(n) => Ok(n)
			_ => Err(WrongType)
		}

	as_fixed64 : Value -> Try(U64, [WrongType])
	as_fixed64 = |value|
		match value {
			Fixed64(n) => Ok(n)
			_ => Err(WrongType)
		}

	as_sfixed32 : Value -> Try(I32, [WrongType])
	as_sfixed32 = |value| as_fixed32(value).map_ok(|n| n.to_i32_wrap())

	as_sfixed64 : Value -> Try(I64, [WrongType])
	as_sfixed64 = |value| as_fixed64(value).map_ok(|n| n.to_i64_wrap())

	as_float : Value -> Try(F32, [WrongType])
	as_float = |value| as_fixed32(value).map_ok(F32.from_bits)

	as_double : Value -> Try(F64, [WrongType])
	as_double = |value| as_fixed64(value).map_ok(F64.from_bits)

	as_bytes : Value -> Try(List(U8), [WrongType])
	as_bytes = |value|
		match value {
			Bytes(b) => Ok(b)
			_ => Err(WrongType)
		}

	## A `string`: fails with `BadUtf8` if the bytes aren't UTF-8, as proto3
	## requires them to be.
	as_string : Value -> Try(Str, [WrongType, BadUtf8])
	as_string = |value|
		match as_bytes(value) {
			Err(WrongType) => Err(WrongType)
			Ok(b) =>
				match Str.from_utf8(b) {
					Ok(text) => Ok(text)
					Err(_) => Err(BadUtf8)
				}
		}

	## An embedded message's fields.
	as_message : Value -> Try(List((U64, Value)), [WrongType, Truncated, Overlong, BadWireType(U64), BadFieldNumber(U64)])
	as_message = |value|
		match as_bytes(value) {
			Err(WrongType) => Err(WrongType)
			Ok(b) =>
				match decode(b) {
					Ok(fields) => Ok(fields)
					Err(Truncated) => Err(Truncated)
					Err(Overlong) => Err(Overlong)
					Err(BadWireType(t)) => Err(BadWireType(t))
					Err(BadFieldNumber(n)) => Err(BadFieldNumber(n))
				}
		}

	# --- The encoding underneath ---

	## `n` as a base-128 varint: seven bits a byte, least significant first,
	## the top bit set on every byte but the last.
	varint : U64 -> List(U8)
	varint = |n| {
		var $rest = n
		var $out = []
		while $rest >= 128 {
			$out = List.append($out, ($rest % 128).to_u8_wrap() + 128)
			$rest = $rest // 128
		}
		List.append($out, $rest.to_u8_wrap())
	}

	## The varint at `start`, and where the next byte is.
	read_varint : List(U8), U64 -> Try((U64, U64), [Truncated, Overlong])
	read_varint = |data, start| {
		var $value = 0
		var $scale = 1
		var $at = start
		while True {
			b = List.get(data, $at) ?? (return Err(Truncated))
			# Ten bytes at most, the tenth with room for one more bit
			# (64 = 9 * 7 + 1).
			if $at - start == 9 and b > 1 {
				return Err(Overlong)
			}
			$value = $value.plus_wrap((b % 128).to_u64().times_wrap($scale))
			$at = $at + 1
			if b < 128 {
				return Ok(($value, $at))
			}
			$scale = $scale.times_wrap(128)
		}
		crash "unreachable: the loop only exits by returning"
	}

	zigzag : I64 -> U64
	zigzag = |n| if n >= 0 n.to_u64_wrap() * 2 else (0 - (n + 1)).to_u64_wrap() * 2 + 1

	unzigzag : U64 -> I64
	unzigzag = |n| if n % 2 == 0 (n // 2).to_i64_wrap() else 0 - (n // 2).to_i64_wrap() - 1

	as_varint : Value -> Try(U64, [WrongType])
	as_varint = |value|
		match value {
			Varint(n) => Ok(n)
			_ => Err(WrongType)
		}

	unpack_varints : List(U8) -> Try(List(U64), [Truncated, Overlong])
	unpack_varints = |data| {
		var $at = 0
		var $out = []
		while $at < List.len(data) {
			(n, next) = read_varint(data, $at)?
			$out = List.append($out, n)
			$at = next
		}
		Ok($out)
	}

	unpack_fixed : List(U8), U64 -> Try(List(U64), [Truncated])
	unpack_fixed = |data, size| {
		if List.len(data) % size != 0 {
			return Err(Truncated)
		}
		var $at = 0
		var $out = []
		while $at < List.len(data) {
			$out = List.append($out, read_little_endian(data, $at, size)?)
			$at = $at + size
		}
		Ok($out)
	}

	little_endian : U64, U64 -> List(U8)
	little_endian = |value, count| {
		var $rest = value
		var $out = []
		var $i = 0
		while $i < count {
			$out = List.append($out, ($rest % 256).to_u8_wrap())
			$rest = $rest // 256
			$i = $i + 1
		}
		$out
	}

	read_little_endian : List(U8), U64, U64 -> Try(U64, [Truncated])
	read_little_endian = |data, at, count| {
		if at + count > List.len(data) {
			return Err(Truncated)
		}
		var $value = 0
		var $i = count
		while $i > 0 {
			$i = $i - 1
			$value = $value.times_wrap(256) + (List.get(data, at + $i) ?? 0).to_u64()
		}
		Ok($value)
	}
}

# --- Tests ---
#
# The byte lists are protoc's encodings of the messages in
# testdata/make_vectors.sh, of testdata/vectors.proto; encoding the same
# fields here must give the same bytes, and decoding them must give back the
# same values.

scalars_bytes = [8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 16, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1, 24, 255, 255, 255, 255, 15, 32, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 40, 255, 255, 255, 255, 15, 48, 1, 56, 1, 69, 7, 0, 0, 0, 73, 255, 255, 255, 255, 255, 255, 255, 255, 85, 254, 255, 255, 255, 89, 253, 255, 255, 255, 255, 255, 255, 255, 101, 0, 0, 192, 63, 105, 0, 0, 0, 0, 0, 0, 208, 191, 114, 10, 104, 195, 169, 108, 108, 111, 32, 226, 156, 147, 122, 3, 0, 1, 255]

scalars_fields = [
	(1, Protobuf.int32(-1)),
	(2, Protobuf.int64(-9223372036854775808)),
	(3, Protobuf.uint32(4294967295)),
	(4, Protobuf.uint64(18446744073709551615)),
	(5, Protobuf.sint32(-2147483648)),
	(6, Protobuf.sint64(-1)),
	(7, Protobuf.bool(True)),
	(8, Protobuf.fixed32(7)),
	(9, Protobuf.fixed64(18446744073709551615)),
	(10, Protobuf.sfixed32(-2)),
	(11, Protobuf.sfixed64(-3)),
	(12, Protobuf.float(1.5)),
	(13, Protobuf.double(-0.25)),
	(14, Protobuf.string("héllo ✓")),
	(15, Protobuf.bytes([0, 1, 255])),
]

collections_bytes = [10, 13, 1, 150, 1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 16, 3, 16, 142, 2, 26, 1, 97, 26, 0, 34, 6, 8, 150, 1, 18, 1, 120, 42, 2, 8, 1, 42, 3, 18, 1, 121, 50, 3, 1, 2, 127, 58, 16, 0, 0, 0, 0, 0, 0, 240, 63, 0, 0, 0, 0, 0, 0, 4, 192]

collections_fields = [
	(1, Protobuf.packed([Protobuf.int32(1), Protobuf.int32(150), Protobuf.int32(-1)])),
	(2, Protobuf.uint64(3)),
	(2, Protobuf.uint64(270)),
	(3, Protobuf.string("a")),
	(3, Protobuf.string("")),
	(4, Protobuf.message([(1, Protobuf.int32(150)), (2, Protobuf.string("x"))])),
	(5, Protobuf.message([(1, Protobuf.int32(1))])),
	(5, Protobuf.message([(2, Protobuf.string("y"))])),
	(6, Protobuf.packed([Protobuf.sint64(-1), Protobuf.sint64(1), Protobuf.sint64(-64)])),
	(7, Protobuf.packed([Protobuf.double(1.0), Protobuf.double(-2.5)])),
]

expect Protobuf.encode(scalars_fields) == scalars_bytes
expect Protobuf.decode(scalars_bytes) == Ok(scalars_fields)
expect Protobuf.encode(collections_fields) == collections_bytes
expect Protobuf.decode(collections_bytes) == Ok(collections_fields)

# The highest field number protobuf allows, 2^29 - 1.
expect Protobuf.encode([(536870911, Protobuf.uint32(1))]) == [248, 255, 255, 255, 15, 1]
expect Protobuf.decode([248, 255, 255, 255, 15, 1]) == Ok([(536870911, Varint(1))])

expect Protobuf.encode([]) == []
expect Protobuf.decode([]) == Ok([])

# Reading values back as their protobuf types.
expect {
	fields = Protobuf.decode(scalars_bytes) ?? []
	read = |number, reader| Protobuf.get(fields, number, reader)
	(read(1, Protobuf.as_int32), read(2, Protobuf.as_int64), read(5, Protobuf.as_sint32), read(6, Protobuf.as_sint64))
	== (Ok(-1), Ok(-9223372036854775808), Ok(-2147483648), Ok(-1))
}
expect {
	fields = Protobuf.decode(scalars_bytes) ?? []
	(
		Protobuf.get(fields, 7, Protobuf.as_bool),
		Protobuf.get(fields, 10, Protobuf.as_sfixed32),
		Protobuf.get(fields, 11, Protobuf.as_sfixed64),
		Protobuf.get(fields, 14, Protobuf.as_string),
	)
	== (Ok(True), Ok(-2), Ok(-3), Ok("héllo ✓"))
}
expect {
	fields = Protobuf.decode(scalars_bytes) ?? []
	(Protobuf.get(fields, 12, Protobuf.as_float), Protobuf.get(fields, 13, Protobuf.as_double))
	== (Ok(1.5), Ok(-0.25))
}

# Repeated fields, packed or not (protobuf accepts either form for numbers).
expect {
	fields = Protobuf.decode(collections_bytes) ?? []
	(Protobuf.repeated_varints(fields, 1), Protobuf.repeated_varints(fields, 2), Protobuf.repeated_fixed64(fields, 7).map_ok(|bits| List.map(bits, F64.from_bits)))
	== (Ok([1, 150, 18446744073709551615]), Ok([3, 270]), Ok([1.0, -2.5]))
}
expect {
	fields = Protobuf.decode(collections_bytes) ?? []
	zigzags = Protobuf.repeated_varints(fields, 6).map_ok(|ns| List.map(ns, |n| Protobuf.as_sint64(Varint(n)) ?? 0))
	names = List.map(Protobuf.repeated(fields, 3), |v| Protobuf.as_string(v) ?? "?")
	(zigzags, names) == (Ok([-1, 1, -64]), ["a", ""])
}
expect {
	# The same numbers sent packed and unpacked, mixed, read as one list.
	fields = [(1, Protobuf.packed([Varint(1), Varint(2)])), (1, Varint(3)), (1, Protobuf.packed([Varint(4)]))]
	Protobuf.repeated_varints(fields, 1) == Ok([1, 2, 3, 4])
}

# Nested messages.
expect {
	fields = Protobuf.decode(collections_bytes) ?? []
	inner = Protobuf.get(fields, 4, Protobuf.as_message) ?? []
	(Protobuf.get(inner, 1, Protobuf.as_int32), Protobuf.get(inner, 2, Protobuf.as_string))
	== (Ok(150), Ok("x"))
}

# Protobuf's reading rules: the last value of a scalar counts, fields in any
# order, unknown fields carried along for the reader to ignore.
expect {
	fields = Protobuf.decode(Protobuf.encode([(99, Protobuf.string("unknown")), (1, Varint(5)), (1, Varint(7))])) ?? []
	(Protobuf.last(fields, 1), Protobuf.last(fields, 2), List.len(fields)) == (Ok(Varint(7)), Err(Missing), 3)
}

# Bad input.
expect Protobuf.decode([8]) == Err(Truncated)
expect Protobuf.decode([18, 5, 1, 2]) == Err(Truncated)
expect Protobuf.decode([9, 1, 2, 3]) == Err(Truncated)
expect Protobuf.decode([8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 2]) == Err(Overlong)
expect Protobuf.decode([8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1]) == Err(Overlong)
expect Protobuf.decode([11]) == Err(BadWireType(3))
expect Protobuf.decode([0, 1]) == Err(BadFieldNumber(0))
expect Protobuf.as_string(Bytes([255])) == Err(BadUtf8)
expect Protobuf.as_int32(Bytes([])) == Err(WrongType)
