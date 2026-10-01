app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Channel
import pf.Framing
import pf.Select
import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Time

# Demonstrates: channels between tasks, a hub that owns shared state, and
# `Select` to wait for whichever happens first
#
# Usage: chat_server [ADDRESS] [SECONDS]
#
# Connect with `nc 127.0.0.1 8080` from several terminals. Type a name, then
# chat. `/who` lists who's here and `/quit` leaves. After a minute of
# silence (or SECONDS) the server asks if you're still there; stay quiet as
# long again and it disconnects you.
#
# One hub task owns the list of users and does all broadcasting, so nothing
# else touches shared state. Each connection has one task, which waits (with
# `Select`) for a line from its user, a message for its user from the hub, or
# its user's silence. The hub never waits on a user: if someone stops reading
# and their outbox fills up, they miss messages instead of stalling the room.

Event : [
	Join({ id : U64, name : Str, outbox : Channel.Sender(Str) }),
	Say(U64, Str),
	Who(U64),
	Leave(U64),
]

main! : List(Str) => Try({}, _)
main! = |args| {
	address =
		match List.get(args, 1) {
			Ok(arg) => arg
			Err(_) => "127.0.0.1:8080"
		}
	patience =
		match List.get(args, 2) {
			Ok(arg) =>
				match U64.from_str(arg) {
					Ok(seconds) => Time.seconds(seconds)
					Err(_) => return Err(BadSeconds(arg))
				}
			Err(_) => Time.seconds(60)
		}

	(events, hub_inbox) = Channel.new!(256)?
	_ = Task.spawn!(|| hub!(hub_inbox))?

	# `chat!` handles silence itself (the heartbeat), so turn off the
	# listener's idle timeout, which would otherwise end a quiet user's read
	# after a minute whatever `patience` is.
	listener = Tcp.listen_with!(address, Tcp.listen_config.with_idle_timeout(NoTimeout))?
	Stdout.line!("Chat server listening on ${address}")?

	var $next_id = 1.U64
	while True {
		stream = listener.accept!()?
		id = $next_id
		$next_id = $next_id + 1
		_ = Task.spawn!(|| serve!(stream, id, events, patience))
	}

	Ok({})
}

## The hub: the only task that knows who's connected.
hub! : Channel.Receiver(Event) => Try({}, _)
hub! = |inbox| {
	var $users = []
	while True {
		match inbox.receive!() {
			Ok(Join(user)) => {
				broadcast!($users, "* ${user.name} joined")
				$users = List.append($users, user)
				tell!($users, user.id, "* ${List.len($users).to_str()} here. /who lists them, /quit leaves.")
			}
			Ok(Say(id, text)) => {
				others = List.keep_if($users, |user| user.id != id)
				broadcast!(others, "<${name_of($users, id)}> ${text}")
			}
			Ok(Who(id)) => {
				names = Str.join_with($users.map(|user| user.name), ", ")
				tell!($users, id, "* here: ${names}")
			}
			Ok(Leave(id)) => {
				name = name_of($users, id)
				# Dropping the user's outbox sender ends their writer task.
				$users = List.keep_if($users, |user| user.id != id)
				broadcast!($users, "* ${name} left")
			}
			Err(ChannelClosed) | Err(Cancelled) => break
		}
	}
	Ok({})
}

broadcast! = |users, line| {
	for user in users {
		# A full outbox means that user isn't keeping up; skip them.
		_ = user.outbox.try_send!(line)
	}
}

tell! = |users, id, line| broadcast!(List.keep_if(users, |user| user.id == id), line)

name_of = |users, id|
	match List.find_first(users, |user| user.id == id) {
		Ok(user) => user.name
		Err(_) => "someone"
	}

## One connection's task: ask for a name, join the hub, then chat until the
## user quits, hangs up, or stops answering.
serve! = |stream, id, hub, patience| {
	stream.write_str!("Welcome! What's your name?\n")?
	(name, reader) = Framing.reader_with_max(stream, 4096).read_line!()?
	(outbox, deliveries) = Channel.new!(64)?
	hub.send!(Join({ id, name: if Str.is_empty(Str.trim(name)) "anonymous" else Str.trim(name), outbox }))?

	result = chat!(stream, reader, deliveries, id, hub, patience)
	# Leave even if the connection failed, so the hub forgets this user.
	hub.send!(Leave(id))?
	match result {
		# Closing a chat window abruptly is a normal way to leave.
		Err(TcpErr(ConnectionReset)) => Ok({})
		other => other
	}
}

## Wait for whichever comes first: a line from the user (to the hub), a
## message for the user (to the socket), or `patience` since the user last
## said anything. Then, a heartbeat: ask whether they're still there, and
## disconnect them after as long again. A person who's around answers;
## a dead connection, or an idle attacker holding it open, doesn't.
chat! = |stream, start, deliveries, id, hub, patience| {
	var $reader = start
	var $last_heard = Time.now!()
	var $warned = False
	while True {
		# Messages from others don't count as the user being there.
		silence_left = patience.minus($last_heard.elapsed!())
		next = Select.new({})
			.on_line($reader, |result| FromUser(result))
			.on_receive(deliveries, |result| ToUser(result))
			.on_timeout(silence_left, || Silent)
			.wait!()?
		match next {
			FromUser(Ok((line, rest))) => {
				$reader = rest
				$last_heard = Time.now!()
				$warned = False
				match line {
					"/quit" => break
					"/who" => hub.send!(Who(id))?
					_ => hub.send!(Say(id, line))?
				}
			}
			FromUser(Err(EndOfStream)) => break
			FromUser(Err(err)) => return Err(err)
			ToUser(Ok(message)) => stream.write_str!("${message}\n")?
			# The hub dropped this user's outbox: it's shutting down.
			ToUser(Err(ChannelClosed)) => break
			Silent => {
				if $warned {
					stream.write_str!("* disconnecting: no reply\n")?
					break
				}
				stream.write_str!("* still there? type anything soon to stay\n")?
				$last_heard = Time.now!()
				$warned = True
			}
		}
	}
	Ok({})
}
