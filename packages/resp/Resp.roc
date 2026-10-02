## RESP, the Redis serialization protocol (RESP2 and RESP3), spoken by
## Redis, Valkey, KeyDB and others
## (https://redis.io/docs/latest/develop/reference/protocol-spec/).
##
## `parse` reads one value from the bytes buffered so far, in the shape a
## `Framing` reader's `read_parsed!` wants, so a client reads replies (and
## a server reads commands) with any stream, and a `Select` waits for one
## with `on_parsed`:
##
## ```roc
## stream = Tcp.connect!("127.0.0.1:6379")?
## reader = Framing.reader(stream)
## (reply, reader2) = Resp.request!(stream, reader, ["SET", "greeting", "hello"])?
## # reply == SimpleString("OK")
## (value, _) = Resp.request!(stream, reader2, ["GET", "greeting"])?
## # value == BulkString(Str.to_utf8("hello"))
## ```
##
## This package needs no platform: its client functions only call the
## stream's `write!` and the reader's `read_parsed!`, so they work with any
## stream type that has them (`Tcp`, `Tls`, `Unix` on roc-net).
Resp := [].{

	## A RESP value. A server's error reply is a value too (`Error`), not a
	## failed read: it's the answer to that command. Values can't be compared
	## with `==`, since a `Double` holds an `F64`; match on them instead.
	Value := [
		## `+OK`: a short reply.
		SimpleString(Str),
		## `-ERR ...`: an error reply.
		Error(Str),
		## `:42`
		Integer(I64),
		## `$5 hello`: binary-safe bytes (often UTF-8 text).
		BulkString(List(U8)),
		## A missing value: RESP2's null bulk string and null array, and
		## RESP3's `_`.
		Null,
		## `*2 ...`
		Array(List(Value)),
		## RESP3 `#t` / `#f`.
		Boolean(Bool),
		## RESP3 `,1.5` (also `inf`, `-inf` and `nan`).
		Double(F64),
		## RESP3 `(`: an integer too big for 64 bits, as its digits.
		BigNumber(Str),
		## RESP3 `!`: an error with binary-safe text.
		BulkError(List(U8)),
		## RESP3 `=`: text with a three-letter format, such as `txt` or `mkd`.
		Verbatim({ format : Str, text : List(U8) }),
		## RESP3 `%`: key-value pairs, in the order sent.
		Map(List((Value, Value))),
		## RESP3 `~`
		Set(List(Value)),
		## RESP3 `>`: data the server pushes without being asked (pub/sub).
		Push(List(Value)),
	]

	## One value from the start of `buffered`: `Parsed(value, used)` with the
	## number of bytes it took, `NeedMore` if `buffered` holds only part of
	## one, or `Malformed(reason)`. RESP3 attributes (`|`), which carry
	## side information a client may ignore, are read and dropped: the value
	## after them is returned. Nesting deeper than 512 levels is `Malformed`,
	## so a hostile peer can't use up the stack.
	parse : List(U8) -> [Parsed(Value, U64), NeedMore, Malformed(Str)]
	parse = |buffered|
		match parse_at(buffered, 0, 0) {
			Got(value, next) => Parsed(value, next)
			More => NeedMore
			Bad(reason) => Malformed(reason)
		}

	## `value` in RESP: RESP3's forms for the RESP3 types, and `_` for `Null`.
	encode : Value -> List(U8)
	encode = |value|
		match value {
			SimpleString(s) => line("+", s)
			Error(s) => line("-", s)
			Integer(n) => line(":", n.to_str())
			BulkString(bytes) => bulk("$", bytes)
			Null => Str.to_utf8("_\r\n")
			Array(items) => aggregate("*", items)
			Boolean(b) => line("#", if b "t" else "f")
			Double(f) => line(",", double_text(f))
			BigNumber(digits) => line("(", digits)
			BulkError(bytes) => bulk("!", bytes)
			Verbatim({ format, text }) => bulk("=", List.concat(Str.to_utf8("${format}:"), text))
			Map(pairs) => List.fold(pairs, line("%", List.len(pairs).to_str()), |out, (k, v)| List.concat(List.concat(out, encode(k)), encode(v)))
			Set(items) => aggregate("~", items)
			Push(items) => aggregate(">", items)
		}

	## A command as clients send it: an array of bulk strings,
	## `["SET", "key", "value"]`.
	command : List(Str) -> List(U8)
	command = |args| command_bytes(List.map(args, Str.to_utf8))

	## `command` with binary-safe arguments.
	command_bytes : List(List(U8)) -> List(U8)
	command_bytes = |args| encode(Array(List.map(args, |arg| BulkString(arg))))

	## The arguments of a command a client sent (an array of bulk strings),
	## for a server reading them with `parse`.
	command_args : Value -> Try(List(List(U8)), [NotACommand])
	command_args = |value|
		match value {
			Array(items) =>
				List.fold(items, Ok([]), |acc, item|
					match (acc, item) {
						(Ok(args), BulkString(arg)) => Ok(List.append(args, arg))
						_ => Err(NotACommand)
					})
			_ => Err(NotACommand)
		}

	## Send `args` as a command on `stream`, and read the reply from
	## `reader` (a `Framing` reader of the same stream): the reply, and the
	## reader to use next. An `Error` reply is a reply, returned as `Ok`.
	request! = |stream, reader, args| {
		stream.write!(command(args))?
		reader.read_parsed!(parse)
	}

	## Send several commands at once and read their replies, in order:
	## pipelining, one round trip for the lot instead of one each.
	pipeline! = |stream, reader, commands| {
		stream.write!(List.join(List.map(commands, command)))?
		var $reader = reader
		var $replies = []
		for _ in commands {
			(reply, next) = $reader.read_parsed!(parse)?
			$replies = List.append($replies, reply)
			$reader = next
		}
		Ok(($replies, $reader))
	}

	# --- Parsing ---

	max_depth : U64
	max_depth = 512

	parse_at : List(U8), U64, U64 -> [Got(Value, U64), More, Bad(Str)]
	parse_at = |buffered, at, depth| {
		if depth > max_depth {
			return Bad("nested more than ${max_depth.to_str()} levels deep")
		}
		kind = List.get(buffered, at) ?? (return More)
		(text, after) =
			match line_at(buffered, at + 1) {
				Found(t, a) => (t, a)
				More => return More
				Bad(reason) => return Bad(reason)
			}
		match kind {
			43 => to_got(text_of(text), |s| SimpleString(s), after)
			45 => to_got(text_of(text), |s| Error(s), after)
			58 =>
				match number(text) {
					Ok(n) => Got(Integer(n), after)
					Err(reason) => Bad(reason)
				}
			36 => bulk_at(buffered, text, after, |bytes| BulkString(bytes), True)
			33 => bulk_at(buffered, text, after, |bytes| BulkError(bytes), False)
			61 =>
				match bulk_at(buffered, text, after, |bytes| BulkString(bytes), False) {
					Got(BulkString(bytes), next) =>
						if List.get(bytes, 3) == Ok(58) {
							match Str.from_utf8(List.take_first(bytes, 3)) {
								Ok(format) => Got(Verbatim({ format, text: List.drop_first(bytes, 4) }), next)
								Err(_) => Bad("a verbatim string's format isn't text")
							}
						} else {
							Bad("a verbatim string must start with a format and a colon")
						}
					Got(_, _) => Bad("unreachable")
					More => More
					Bad(reason) => Bad(reason)
				}
			95 => if List.is_empty(text) Got(Null, after) else Bad("null with data after it")
			35 =>
				match text {
					[116] => Got(Boolean(True), after)
					[102] => Got(Boolean(False), after)
					_ => Bad("a boolean must be t or f")
				}
			44 =>
				match double(text) {
					Ok(f) => Got(Double(f), after)
					Err(reason) => Bad(reason)
				}
			40 =>
				match text_of(text) {
					Ok(digits) if is_integer_text(digits) => Got(BigNumber(digits), after)
					_ => Bad("a big number must be digits")
				}
			42 => items_at(buffered, text, after, depth, |items| Array(items), True)
			126 => items_at(buffered, text, after, depth, |items| Set(items), False)
			62 => items_at(buffered, text, after, depth, |items| Push(items), False)
			37 =>
				match count(text) {
					Err(reason) => Bad(reason)
					Ok(n) =>
						match items_from(buffered, after, depth, n * 2) {
							Got2(items, next) => Got(Map(pairs(items)), next)
							More2 => More
							Bad2(reason) => Bad(reason)
						}
				}
			124 =>
				# An attribute: its pairs, then the value they describe.
				match count(text) {
					Err(reason) => Bad(reason)
					Ok(n) =>
						match items_from(buffered, after, depth, n * 2) {
							Got2(_, next) => parse_at(buffered, next, depth + 1)
							More2 => More
							Bad2(reason) => Bad(reason)
						}
				}
			other => Bad("unknown type byte ${other.to_str()}")
		}
	}

	## The text after a type byte, up to its `\r\n`, and where the next byte is.
	line_at : List(U8), U64 -> [Found(List(U8), U64), More, Bad(Str)]
	line_at = |buffered, start| {
		var $i = start
		while $i < List.len(buffered) {
			if List.get(buffered, $i) == Ok(13) {
				return
					match List.get(buffered, $i + 1) {
						Ok(10) => Found(List.sublist(buffered, { start, len: $i - start }), $i + 2)
						Ok(_) => Bad("a \\r not followed by \\n")
						Err(_) => More
					}
			}
			$i = $i + 1
		}
		More
	}

	bulk_at : List(U8), List(U8), U64, (List(U8) -> Value), Bool -> [Got(Value, U64), More, Bad(Str)]
	bulk_at = |buffered, text, after, wrap, null_allowed| {
		if null_allowed and text == [45, 49] {
			return Got(Null, after)
		}
		len =
			match count(text) {
				Ok(n) => n
				Err(reason) => return Bad(reason)
			}
		if List.len(buffered) < after + len + 2 {
			return More
		}
		if List.sublist(buffered, { start: after + len, len: 2 }) != [13, 10] {
			return Bad("a bulk string longer than its length says")
		}
		Got(wrap(List.sublist(buffered, { start: after, len })), after + len + 2)
	}

	items_at : List(U8), List(U8), U64, U64, (List(Value) -> Value), Bool -> [Got(Value, U64), More, Bad(Str)]
	items_at = |buffered, text, after, depth, wrap, null_allowed| {
		if null_allowed and text == [45, 49] {
			return Got(Null, after)
		}
		match count(text) {
			Err(reason) => Bad(reason)
			Ok(n) =>
				match items_from(buffered, after, depth, n) {
					Got2(items, next) => Got(wrap(items), next)
					More2 => More
					Bad2(reason) => Bad(reason)
				}
		}
	}

	items_from : List(U8), U64, U64, U64 -> [Got2(List(Value), U64), More2, Bad2(Str)]
	items_from = |buffered, start, depth, n| {
		var $at = start
		var $items = []
		var $i = 0
		while $i < n {
			match parse_at(buffered, $at, depth + 1) {
				Got(item, next) => {
					$items = List.append($items, item)
					$at = next
				}
				More => return More2
				Bad(reason) => return Bad2(reason)
			}
			$i = $i + 1
		}
		Got2($items, $at)
	}

	pairs : List(Value) -> List((Value, Value))
	pairs = |items| {
		var $out = []
		var $i = 0
		while $i + 1 < List.len(items) {
			match (List.get(items, $i), List.get(items, $i + 1)) {
				(Ok(k), Ok(v)) => {
					$out = List.append($out, (k, v))
				}
				_ => {}
			}
			$i = $i + 2
		}
		$out
	}

	to_got : Try(Str, [BadText]), (Str -> Value), U64 -> [Got(Value, U64), More, Bad(Str)]
	to_got = |text, wrap, after|
		match text {
			Ok(s) => Got(wrap(s), after)
			Err(BadText) => Bad("text that isn't UTF-8")
		}

	text_of : List(U8) -> Try(Str, [BadText])
	text_of = |bytes|
		match Str.from_utf8(bytes) {
			Ok(s) => Ok(s)
			Err(_) => Err(BadText)
		}

	number : List(U8) -> Try(I64, Str)
	number = |text|
		match text_of(text) {
			Ok(s) =>
				match I64.from_str(s) {
					Ok(n) => Ok(n)
					Err(_) => Err("not an integer: ${s}")
				}
			Err(_) => Err("not an integer")
		}

	## A length or element count: 0 or more.
	count : List(U8) -> Try(U64, Str)
	count = |text|
		match number(text) {
			Ok(n) if n >= 0 => Ok(n.to_u64_wrap())
			Ok(_) => Err("a negative length")
			Err(reason) => Err(reason)
		}

	double : List(U8) -> Try(F64, Str)
	double = |text|
		match text_of(text) {
			Ok("inf") => Ok(F64.infinity)
			Ok("-inf") => Ok(-F64.infinity)
			Ok("nan") => Ok(F64.nan)
			Ok(s) =>
				match F64.from_str(s) {
					Ok(f) => Ok(f)
					Err(_) => Err("not a double: ${s}")
				}
			Err(_) => Err("not a double")
		}

	is_integer_text : Str -> Bool
	is_integer_text = |s| {
		digits =
			match Str.to_utf8(s) {
				[45, .. as rest] => rest
				all => all
			}
		!List.is_empty(digits) and List.all(digits, |b| b >= 48 and b <= 57)
	}

	# --- Encoding ---

	line : Str, Str -> List(U8)
	line = |prefix, text| Str.to_utf8("${prefix}${text}\r\n")

	bulk : Str, List(U8) -> List(U8)
	bulk = |prefix, bytes| List.concat(List.concat(line(prefix, List.len(bytes).to_str()), bytes), [13, 10])

	aggregate : Str, List(Value) -> List(U8)
	aggregate = |prefix, items| List.fold(items, line(prefix, List.len(items).to_str()), |out, item| List.concat(out, encode(item)))

	double_text : F64 -> Str
	double_text = |f|
		if f.is_nan() {
			"nan"
		} else if f == F64.infinity {
			"inf"
		} else if f == -F64.infinity {
			"-inf"
		} else {
			f.to_str()
		}
}

# --- Tests ---

utf8 = Str.to_utf8

# Values can hold an F64 (`Double`), and floats have no `==`: compare how
# they print instead.
same : [Parsed(Resp.Value, U64), NeedMore, Malformed(Str)], [Parsed(Resp.Value, U64), NeedMore, Malformed(Str)] -> Bool
same = |a, b| Str.inspect(a) == Str.inspect(b)

prefix_lengths = |bytes| {
	var $out = []
	var $n = 0
	while $n < List.len(bytes) {
		$out = List.append($out, $n)
		$n = $n + 1
	}
	$out
}

expect same(Resp.parse(utf8("+OK\r\n")), Parsed(SimpleString("OK"), 5))
expect same(Resp.parse(utf8("-ERR unknown command 'X'\r\n")), Parsed(Error("ERR unknown command 'X'"), 26))
expect same(Resp.parse(utf8(":-42\r\n")), Parsed(Integer(-42), 6))
expect same(Resp.parse(utf8("$5\r\nhello\r\n")), Parsed(BulkString(utf8("hello")), 11))
expect same(Resp.parse(utf8("$0\r\n\r\n")), Parsed(BulkString([]), 6))
expect same(Resp.parse(utf8("$-1\r\n")), Parsed(Null, 5))
expect same(Resp.parse(utf8("*-1\r\n")), Parsed(Null, 5))
expect same(Resp.parse(utf8("_\r\n")), Parsed(Null, 3))
expect same(Resp.parse(utf8("*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n")), Parsed(Array([BulkString(utf8("GET")), BulkString(utf8("key"))]), 22))
expect same(Resp.parse(utf8("*2\r\n*1\r\n:1\r\n*0\r\n")), Parsed(Array([Array([Integer(1)]), Array([])]), 16))
expect same(Resp.parse(utf8("#t\r\n")), Parsed(Boolean(True), 4))
expect same(Resp.parse(utf8(",-1.5\r\n")), Parsed(Double(-1.5), 7))
expect same(Resp.parse(utf8(",inf\r\n")), Parsed(Double(F64.infinity), 6))
expect same(Resp.parse(utf8("(3492890328409238509324850943850943825024385\r\n")), Parsed(BigNumber("3492890328409238509324850943850943825024385"), 46))
expect same(Resp.parse(utf8("!21\r\nSYNTAX invalid syntax\r\n")), Parsed(BulkError(utf8("SYNTAX invalid syntax")), 28))
expect same(Resp.parse(utf8("=15\r\ntxt:Some string\r\n")), Parsed(Verbatim({ format: "txt", text: utf8("Some string") }), 22))
expect same(Resp.parse(utf8("%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n")), Parsed(Map([(SimpleString("first"), Integer(1)), (SimpleString("second"), Integer(2))]), 29))
expect same(Resp.parse(utf8("~2\r\n:1\r\n:2\r\n")), Parsed(Set([Integer(1), Integer(2)]), 12))
expect same(Resp.parse(utf8(">3\r\n$7\r\nmessage\r\n$4\r\nnews\r\n$2\r\nhi\r\n")), Parsed(Push([BulkString(utf8("message")), BulkString(utf8("news")), BulkString(utf8("hi"))]), 35))
# An attribute is read and dropped; the value after it is the reply.
expect same(Resp.parse(utf8("|1\r\n+ttl\r\n:3600\r\n:7\r\n")), Parsed(Integer(7), 21))

# Bytes after the value stay for the next parse.
expect same(Resp.parse(utf8("+OK\r\n:1\r\n")), Parsed(SimpleString("OK"), 5))

# Every split of a value is NeedMore, never a wrong value or Malformed.
expect {
	whole = utf8("*3\r\n$5\r\nhello\r\n%1\r\n+k\r\n,2.5\r\n_\r\n")
	List.all(prefix_lengths(whole), |n| same(Resp.parse(List.take_first(whole, n)), NeedMore))
}

expect same(Resp.parse(utf8("?x\r\n")), Malformed("unknown type byte 63"))
expect same(Resp.parse(utf8(":12x\r\n")), Malformed("not an integer: 12x"))
expect same(Resp.parse(utf8("$3\r\nhello\r\n")), Malformed("a bulk string longer than its length says"))
expect same(Resp.parse(utf8("+a\rb\r\n")), Malformed("a \\r not followed by \\n"))
expect same(Resp.parse(utf8("#x\r\n")), Malformed("a boolean must be t or f"))
expect same(Resp.parse(utf8("*-5\r\n")), Malformed("a negative length"))
expect {
	deep = List.join(List.repeat(utf8("*1\r\n"), 600))
	same(Resp.parse(deep), Malformed("nested more than 512 levels deep"))
}

# Encoding, and back.
expect Resp.command(["SET", "key", "value"]) == utf8("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n")
expect {
	values = [
		SimpleString("OK"), Error("ERR no"), Integer(-7), BulkString([0, 255]), Null,
		Array([Integer(1), Array([])]), Boolean(False), Double(0.5), BigNumber("-123456789012345678901234567890"),
		BulkError(utf8("bad")), Verbatim({ format: "mkd", text: utf8("# hi") }),
		Map([(BulkString(utf8("k")), Set([Integer(2)]))]), Push([SimpleString("pong")]),
	]
	List.all(values, |v| same(Resp.parse(Resp.encode(v)), Parsed(v, List.len(Resp.encode(v)))))
}
expect Resp.command_args(Array([BulkString(utf8("GET")), BulkString(utf8("k"))])) == Ok([utf8("GET"), utf8("k")])
expect Resp.command_args(Array([Integer(1)])) == Err(NotACommand)
