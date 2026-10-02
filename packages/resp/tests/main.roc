app [main!] {
	pf: platform "../../../platform/main.roc",
	resp: "../main.roc",
}

# The resp package's tests that need a network: its client against a small
# server written here with the package (always), and against a real Valkey
# or Redis when VALKEY_ADDRESS is set (`just interop-valkey`).

import pf.Channel
import pf.Env
import pf.Framing
import pf.Select
import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Time
import resp.Resp

main! : List(Str) => Try({}, _)
main! = |_| {
	fake = fake_server!()?
	results = List.concat(
		suite!("fake server", fake),
		match Env.var!("VALKEY_ADDRESS") {
			Ok(address) => suite!("valkey", address)
			Err(_) => []
		},
	)
	failed = List.count_if(results, |passed| !passed)
	if failed == 0 {
		Stdout.line!("All ${List.len(results).to_str()} resp checks passed")
	} else {
		Stdout.line!("${failed.to_str()} resp checks failed")?
		Err(Exit(1))
	}
}

suite! = |name, address| [
	check!("${name}: PING, SET and GET", || {
		stream = Tcp.connect!(address)?
		reader = Framing.reader(stream)
		(pong, r1) = Resp.request!(stream, reader, ["PING"])?
		(set, r2) = Resp.request!(stream, r1, ["SET", "roc-net:greeting", "héllo"])?
		(got, _) = Resp.request!(stream, r2, ["GET", "roc-net:greeting"])?
		expect_eq((show(pong), show(set), show(got)), ("SimpleString(\"PONG\")", "SimpleString(\"OK\")", show(BulkString(Str.to_utf8("héllo")))))
	}),
	check!("${name}: a pipeline of INCRs, one round trip", || {
		stream = Tcp.connect!(address)?
		(_, r1) = Resp.request!(stream, Framing.reader(stream), ["DEL", "roc-net:counter"])?
		(replies, _) = Resp.pipeline!(stream, r1, [["INCR", "roc-net:counter"], ["INCR", "roc-net:counter"], ["INCRBY", "roc-net:counter", "40"]])?
		expect_eq(List.map(replies, show), ["Integer(1)", "Integer(2)", "Integer(42)"])
	}),
	check!("${name}: an error reply is a reply", || {
		stream = Tcp.connect!(address)?
		(reply, _) = Resp.request!(stream, Framing.reader(stream), ["NOSUCHCOMMAND"])?
		is_error =
			match reply {
				Error(_) => True
				_ => False
			}
		expect_eq(is_error, True)
	}),
	check!("${name}: a published message arrives through Select.on_parsed", || {
		subscriber = Tcp.connect!(address)?
		(_, reader) = Resp.request!(subscriber, Framing.reader(subscriber), ["SUBSCRIBE", "roc-net:news"])?
		publisher = Tcp.connect!(address)?
		(_, _) = Resp.request!(publisher, Framing.reader(publisher), ["PUBLISH", "roc-net:news", "hi"])?
		got =
			Select.new({})
				.on_parsed(reader, Resp.parse, |result| Got(result))
				.on_timeout(Time.seconds(5), || Nothing)
				.wait!()?
		message =
			match got {
				Got(Ok((Array([_, _, BulkString(text)]), _))) => Ok(Str.from_utf8_lossy(text))
				Got(Ok((Push([_, _, BulkString(text)]), _))) => Ok(Str.from_utf8_lossy(text))
				Got(other) => Err(Str.inspect(other))
				Nothing => Err("no message")
			}
		expect_eq(message, Ok("hi"))
	}),
]

show = |value| Str.inspect(value)

## A server speaking just enough RESP for the checks above, written with the
## package: reads commands with Resp.parse, answers with Resp.encode.
fake_server! = || {
	listener = Tcp.listen!("127.0.0.1:0")?
	address = listener.local_addr!()?
	(store_tx, store_rx) = Channel.new!(1)?
	store_tx.send!({ values: [], subscribers: [] })?
	_ = Task.spawn!(|| {
		while True {
			stream = listener.accept!()?
			_ = Task.spawn!(|| serve!(stream, store_tx, store_rx))
		}
		Ok({})
	})?
	Ok(address)
}

serve! = |stream, store_tx, store_rx| {
	var $reader = Framing.reader(stream)
	while True {
		(request, next) =
			match $reader.read_parsed!(Resp.parse) {
				Ok(got) => got
				Err(EndOfStream) => return Ok({})
				Err(err) => return Err(err)
			}
		$reader = next
		args = List.map(Resp.command_args(request) ?? [], Str.from_utf8_lossy)
		# The store passes between tasks on a channel: whoever holds it owns it.
		store = store_rx.receive!()?
		(reply, updated) = answer(args, store)
		store_tx.send!(updated)?
		stream.write!(Resp.encode(reply))?
		match args {
			["PUBLISH", channel, message] =>
				for subscriber in updated.subscribers {
					if subscriber.channel == channel {
						_ = subscriber.stream.write!(Resp.encode(Push([BulkString(Str.to_utf8("message")), BulkString(Str.to_utf8(channel)), BulkString(Str.to_utf8(message))])))
					}
				}
			["SUBSCRIBE", channel] => {
				held = store_rx.receive!()?
				store_tx.send!({ ..held, subscribers: List.append(held.subscribers, { channel, stream }) })?
			}
			_ => {}
		}
	}
	Ok({})
}

answer = |args, store|
	match args {
		["PING"] => (SimpleString("PONG"), store)
		["SET", key, value] => (SimpleString("OK"), { ..store, values: List.append(List.drop_if(store.values, |(k, _)| k == key), (key, value)) })
		["GET", key] =>
			match List.find_first(store.values, |(k, _)| k == key) {
				Ok((_, value)) => (BulkString(Str.to_utf8(value)), store)
				Err(_) => (Null, store)
			}
		["DEL", key] => (Integer(if List.any(store.values, |(k, _)| k == key) 1 else 0), { ..store, values: List.drop_if(store.values, |(k, _)| k == key) })
		["INCR", key] => incr_by(store, key, 1)
		["INCRBY", key, by] => incr_by(store, key, I64.from_str(by) ?? 0)
		["SUBSCRIBE", channel] => (Push([BulkString(Str.to_utf8("subscribe")), BulkString(Str.to_utf8(channel)), Integer(1)]), store)
		["PUBLISH", _, _] => (Integer(1), store)
		_ => (Error("ERR unknown command"), store)
	}

incr_by = |store, key, by| {
	current =
		match List.find_first(store.values, |(k, _)| k == key) {
			Ok((_, value)) => I64.from_str(value) ?? 0
			Err(_) => 0
		}
	total = current + by
	(Integer(total), { ..store, values: List.append(List.drop_if(store.values, |(k, _)| k == key), (key, total.to_str())) })
}

check! = |name, test!|
	match test!() {
		Ok({}) => {
			_ = Stdout.line!("ok    ${name}")
			True
		}
		Err(err) => {
			_ = Stdout.line!("FAIL  ${name}: ${Str.inspect(err)}")
			False
		}
	}

expect_eq = |actual, expected|
	if actual == expected {
		Ok({})
	} else {
		Err(Mismatch({ expected: Str.inspect(expected), actual: Str.inspect(actual) }))
	}
