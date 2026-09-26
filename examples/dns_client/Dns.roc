## Build DNS queries and parse DNS responses (RFC 1035).
##
## Everything here is pure: bytes in, values out, no network. That keeps the
## protocol logic testable with `expect` (see the bottom of this file) and
## separate from how the bytes travel, which `main.roc` handles.
import pf.Bytes

Dns := [].{

	RecordType : [A, AAAA, CNAME, MX, NS, PTR, SOA, SRV, TXT, Other(U16)]

	## One resource record from a response.
	Record : { name : Str, type : RecordType, ttl : U32, data : Str }

	Response : {
		id : U16,
		truncated : Bool,
		rcode : U8,
		question : List({ name : Str, type : RecordType }),
		answers : List(Record),
		authority : List(Record),
		additional : List(Record),
	}

	# --- Record types ---

	type_code : RecordType -> U16
	type_code = |type|
		match type {
			A => 1
			NS => 2
			CNAME => 5
			SOA => 6
			PTR => 12
			MX => 15
			TXT => 16
			AAAA => 28
			SRV => 33
			Other(code) => code
		}

	type_from_code : U16 -> RecordType
	type_from_code = |code|
		match code {
			1 => A
			2 => NS
			5 => CNAME
			6 => SOA
			12 => PTR
			15 => MX
			16 => TXT
			28 => AAAA
			33 => SRV
			_ => Other(code)
		}

	type_name : RecordType -> Str
	type_name = |type|
		match type {
			Other(code) => "TYPE${code.to_str()}"
			known => Str.inspect(known)
		}

	## Parse a type such as `"MX"`, `"aaaa"`, or `"TYPE65"` (any type by number).
	parse_type : Str -> Try(RecordType, [UnknownType(Str)])
	parse_type = |text| {
		upper = ascii_upper(text)
		known = [A, AAAA, CNAME, MX, NS, PTR, SOA, SRV, TXT]
		match List.find_first(known, |type| type_name(type) == upper) {
			Ok(type) => Ok(type)
			Err(_) =>
				if Str.starts_with(upper, "TYPE") {
					match U16.from_str(Str.drop_prefix(upper, "TYPE")) {
						Ok(code) => Ok(type_from_code(code))
						Err(_) => Err(UnknownType(text))
					}
				} else {
					Err(UnknownType(text))
				}
		}
	}

	rcode_name : U8 -> Str
	rcode_name = |rcode|
		match rcode {
			0 => "NOERROR"
			1 => "FORMERR"
			2 => "SERVFAIL"
			3 => "NXDOMAIN"
			4 => "NOTIMP"
			5 => "REFUSED"
			_ => "RCODE${rcode.to_str()}"
		}

	# --- Encoding ---

	## A query for `name` and `type`, asking the server to recurse.
	encode_query : U16, Str, RecordType -> Try(List(U8), [BadName(Str)])
	encode_query = |id, name, type| {
		qname = encode_name(name)?
		# Flags 0x0100: a standard query with "recursion desired" set.
		header = List.join([Bytes.u16_be(id), Bytes.u16_be(256), Bytes.u16_be(1), Bytes.u16_be(0), Bytes.u16_be(0), Bytes.u16_be(0)])
		Ok(List.join([header, qname, Bytes.u16_be(type_code(type)), Bytes.u16_be(1)]))
	}

	## `"example.com"` becomes `[7, 'e', ..., 3, 'c', 'o', 'm', 0]`: each label
	## prefixed by its length, ending with an empty label.
	encode_name : Str -> Try(List(U8), [BadName(Str)])
	encode_name = |name| {
		labels = Str.split_on(name, ".").keep_if(|label| !Str.is_empty(label))
		var $encoded = []
		for label in labels {
			bytes = Str.to_utf8(label)
			if List.len(bytes) > 63 {
				return Err(BadName(name))
			}
			$encoded = List.concat(List.append($encoded, List.len(bytes).to_u8_wrap()), bytes)
		}
		if List.len($encoded) >= 255 {
			return Err(BadName(name))
		}
		Ok(List.append($encoded, 0))
	}

	# --- Decoding ---

	decode_response : List(U8) -> Try(Response, [Malformed(Str)])
	decode_response = |msg| {
		id = u16_at(msg, 0)?
		flags = u16_at(msg, 2)?
		question_count = u16_at(msg, 4)?
		answer_count = u16_at(msg, 6)?
		authority_count = u16_at(msg, 8)?
		additional_count = u16_at(msg, 10)?

		var $offset = 12
		var $question = []
		for _ in U16.until(0, question_count) {
			(name, after_name) = read_name(msg, $offset)?
			type = type_from_code(u16_at(msg, after_name)?)
			$question = List.append($question, { name, type })
			$offset = after_name + 4
		}
		(answers, after_answers) = read_records(msg, $offset, answer_count)?
		(authority, after_authority) = read_records(msg, after_answers, authority_count)?
		(additional, _) = read_records(msg, after_authority, additional_count)?

		Ok({
			id,
			# Bit 9 (0x0200) is TC: the reply didn't fit in a datagram.
			truncated: flags // 512 % 2 == 1,
			rcode: (flags % 16).to_u8_wrap(),
			question: $question,
			answers,
			authority,
			additional,
		})
	}

	read_records : List(U8), U64, U16 -> Try((List(Record), U64), [Malformed(Str)])
	read_records = |msg, start, count| {
		var $records = []
		var $offset = start
		for _ in U16.until(0, count) {
			(name, after_name) = read_name(msg, $offset)?
			type = type_from_code(u16_at(msg, after_name)?)
			ttl = u32_at(msg, after_name + 4)?
			data_len = u16_at(msg, after_name + 8)?.to_u64()
			data_start = after_name + 10
			data = format_data(msg, type, data_start, data_len)?
			$records = List.append($records, { name, type, ttl, data })
			$offset = data_start + data_len
		}
		Ok(($records, $offset))
	}

	## Read a possibly compressed name starting at `start`. Returns the name and
	## the offset just past it (past the first pointer, if it used one).
	##
	## Compression: a length byte with its top two bits set is instead a 14-bit
	## pointer to where the rest of the name was already written. A reply can
	## point in a circle, so give up after a bounded number of jumps.
	read_name : List(U8), U64 -> Try((Str, U64), [Malformed(Str)])
	read_name = |msg, start| {
		var $labels = []
		var $position = start
		var $after = 0
		var $jumps = 0
		while True {
			length = u8_at(msg, $position)?
			if length == 0 {
				if $jumps == 0 {
					$after = $position + 1
				}
				break
			} else if length >= 192 {
				low = u8_at(msg, $position + 1)?
				if $jumps == 0 {
					$after = $position + 2
				}
				$jumps = $jumps + 1
				if $jumps > 32 {
					return Err(Malformed("name compression loop"))
				}
				$position = (length - 192).to_u64() * 256 + low.to_u64()
			} else if length >= 64 {
				return Err(Malformed("invalid label length ${length.to_str()}"))
			} else {
				label = slice(msg, $position + 1, length.to_u64())?
				$labels = List.append($labels, Str.from_utf8_lossy(label))
				$position = $position + 1 + length.to_u64()
			}
		}
		Ok((Str.concat(Str.join_with($labels, "."), "."), $after))
	}

	## Render a record's data the way `dig` does.
	format_data : List(U8), RecordType, U64, U64 -> Try(Str, [Malformed(Str)])
	format_data = |msg, type, start, len| {
		data = slice(msg, start, len)?
		match type {
			A =>
				match data {
					[a, b, c, d] => Ok("${a.to_str()}.${b.to_str()}.${c.to_str()}.${d.to_str()}")
					_ => Err(Malformed("A record is not 4 bytes"))
				}
			AAAA => format_ipv6(data)
			NS | CNAME | PTR => read_name(msg, start).map_ok(|(name, _)| name)
			MX => {
				preference = u16_at(msg, start)?
				(exchange, _) = read_name(msg, start + 2)?
				Ok("${preference.to_str()} ${exchange}")
			}
			SRV => {
				priority = u16_at(msg, start)?
				weight = u16_at(msg, start + 2)?
				port = u16_at(msg, start + 4)?
				(target, _) = read_name(msg, start + 6)?
				Ok("${priority.to_str()} ${weight.to_str()} ${port.to_str()} ${target}")
			}
			SOA => {
				(primary, after_primary) = read_name(msg, start)?
				(mailbox, after_mailbox) = read_name(msg, after_primary)?
				numbers = [0, 4, 8, 12, 16].map(|at| u32_at(msg, after_mailbox + at))
				match numbers {
					[Ok(serial), Ok(refresh), Ok(retry), Ok(expire), Ok(minimum)] =>
						Ok("${primary} ${mailbox} ${serial.to_str()} ${refresh.to_str()} ${retry.to_str()} ${expire.to_str()} ${minimum.to_str()}")
					_ => Err(Malformed("SOA record ends early"))
				}
			}
			TXT => format_txt(data)
			Other(_) => Ok("\\# ${len.to_str()} ${hex_bytes(data)}")
		}
	}

	## TXT data is a sequence of length-prefixed strings.
	format_txt : List(U8) -> Try(Str, [Malformed(Str)])
	format_txt = |data| {
		var $rest = data
		var $parts = []
		while !List.is_empty($rest) {
			(length, after_length) =
				match Bytes.take_u8($rest) {
					Ok(taken) => taken
					Err(TooShort) => return Err(Malformed("TXT record ends early"))
				}
			(text, after_text) =
				match Bytes.take(after_length, length.to_u64()) {
					Ok(taken) => taken
					Err(TooShort) => return Err(Malformed("TXT string ends early"))
				}
			$parts = List.append($parts, Str.inspect(Str.from_utf8_lossy(text)))
			$rest = after_text
		}
		Ok(Str.join_with($parts, " "))
	}

	## Format 16 bytes as an IPv6 address in the standard short form (RFC 5952):
	## lowercase hex groups without leading zeros, and the longest run of two
	## or more zero groups written as `::`.
	format_ipv6 : List(U8) -> Try(Str, [Malformed(Str)])
	format_ipv6 = |data| {
		if List.len(data) != 16 {
			return Err(Malformed("AAAA record is not 16 bytes"))
		}
		var $groups = []
		for i in U64.until(0, 8) {
			$groups = List.append($groups, u16_at(data, i * 2)?)
		}
		groups = $groups

		# Find the longest run of zero groups (the first, if tied).
		var $best_start = 0
		var $best_len = 0
		var $run_start = 0
		var $run_len = 0
		for i in U64.until(0, 8) {
			if List.get(groups, i) == Ok(0) {
				if $run_len == 0 {
					$run_start = i
				}
				$run_len = $run_len + 1
				if $run_len > $best_len {
					$best_start = $run_start
					$best_len = $run_len
				}
			} else {
				$run_len = 0
			}
		}

		hex_groups = groups.map(hex_u16)
		if $best_len < 2 {
			Ok(Str.join_with(hex_groups, ":"))
		} else {
			before = Str.join_with(List.take_first(hex_groups, $best_start), ":")
			after = Str.join_with(List.drop_first(hex_groups, $best_start + $best_len), ":")
			Ok("${before}::${after}")
		}
	}

	# --- Byte helpers ---

	slice : List(U8), U64, U64 -> Try(List(U8), [Malformed(Str)])
	slice = |msg, offset, count|
		if offset + count > List.len(msg) {
			Err(Malformed("message ends early"))
		} else {
			Ok(List.sublist(msg, { start: offset, len: count }))
		}

	u8_at : List(U8), U64 -> Try(U8, [Malformed(Str)])
	u8_at = |msg, offset|
		match List.get(msg, offset) {
			Ok(byte) => Ok(byte)
			Err(_) => Err(Malformed("message ends early"))
		}

	u16_at : List(U8), U64 -> Try(U16, [Malformed(Str)])
	u16_at = |msg, offset|
		match Bytes.take_u16_be(slice(msg, offset, 2)?) {
			Ok((n, _)) => Ok(n)
			Err(TooShort) => Err(Malformed("message ends early"))
		}

	u32_at : List(U8), U64 -> Try(U32, [Malformed(Str)])
	u32_at = |msg, offset|
		match Bytes.take_u32_be(slice(msg, offset, 4)?) {
			Ok((n, _)) => Ok(n)
			Err(TooShort) => Err(Malformed("message ends early"))
		}

	hex_digit : U8 -> U8
	hex_digit = |n| if n < 10 48 + n else 87 + n

	## Lowercase hex without leading zeros: 0 is "0", 0x0db8 is "db8".
	hex_u16 : U16 -> Str
	hex_u16 = |n| {
		var $digits = []
		var $rest = n
		while True {
			$digits = List.prepend($digits, hex_digit(($rest % 16).to_u8_wrap()))
			$rest = $rest // 16
			if $rest == 0 {
				break
			}
		}
		Str.from_utf8_lossy($digits)
	}

	hex_bytes : List(U8) -> Str
	hex_bytes = |bytes|
		Str.from_utf8_lossy(List.join(bytes.map(|b| [hex_digit(b // 16), hex_digit(b % 16)])))

	ascii_upper : Str -> Str
	ascii_upper = |text|
		Str.from_utf8_lossy(Str.to_utf8(text).map(|b| if b >= 97 and b <= 122 b - 32 else b))
}

# --- Tests: `roc test examples/dns_client/main.roc` ---

expect Dns.encode_query(4660, "example.com", A) == Ok([18, 52, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1])

expect Dns.encode_name("a.") == Ok([1, 97, 0])

expect Dns.encode_name(Str.repeat("x", 64)) == Err(BadName(Str.repeat("x", 64)))

expect Dns.parse_type("mx") == Ok(MX)

expect Dns.parse_type("TYPE65") == Ok(Other(65))

expect Dns.parse_type("nope") == Err(UnknownType("nope"))

# A reply for example.com A whose answer names the domain with a compression
# pointer (192, 12) back to the question at offset 12.
example_reply = [
	18, 52, 129, 128, 0, 1, 0, 1, 0, 0, 0, 0,
	7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1,
	192, 12, 0, 1, 0, 1, 0, 0, 14, 16, 0, 4, 93, 184, 215, 14,
]

expect {
	reply = Dns.decode_response(example_reply)
	reply.map_ok(|r| (r.id, r.truncated, r.rcode, r.answers))
	== Ok((4660, False, 0, [{ name: "example.com.", type: A, ttl: 3600, data: "93.184.215.14" }]))
}

# A name that points at itself must fail rather than loop forever.
expect Dns.read_name([192, 0], 0) == Err(Malformed("name compression loop"))

expect Dns.decode_response([18, 52, 129]) == Err(Malformed("message ends early"))

expect Dns.format_ipv6([32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]) == Ok("2001:db8::1")

expect Dns.format_ipv6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]) == Ok("::1")

expect Dns.format_ipv6([32, 1, 13, 184, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1]) == Ok("2001:db8:0:1::1")

expect Dns.format_txt([5, 104, 101, 108, 108, 111, 2, 104, 105]) == Ok("\"hello\" \"hi\"")
