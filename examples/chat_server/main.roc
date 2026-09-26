app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Channel
import pf.Framing
import pf.Stdout
import pf.Task
import pf.Tcp

# Demonstrates: channels between tasks, a hub that owns shared state
#
# Usage: chat_server [ADDRESS]
#
# Connect with `nc 127.0.0.1 8080` from several terminals. Type a name, then
# chat. `/who` lists who's here and `/quit` leaves.
#
# One hub task owns the list of users and does all broadcasting, so nothing
# else touches shared state. Each connection has a reader task, which turns
# lines into events for the hub, and a writer task, which sends that user's
# outbox to the socket. The hub never waits on a user: if someone stops
# reading and their outbox fills up, they miss messages instead of stalling
# the room.

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

	(events, hub_inbox) = Channel.new!(256)?
	Task.spawn!(|| hub!(hub_inbox))?

	listener = Tcp.listen!(address)?
	Stdout.line!("Chat server listening on ${address}")?

	var $next_id = 1.U64
	while True {
		stream = listener.accept!()?
		id = $next_id
		$next_id = $next_id + 1
		_ = Task.spawn!(|| serve!(stream, id, events))
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
			Err(ChannelClosed) => break
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

## One connection: ask for a name, start a writer, then forward lines to the
## hub until the user quits or hangs up.
serve! = |stream, id, hub| {
	stream.write_str!("Welcome! What's your name?\n")?
	(name, reader) = Framing.reader_with_max(stream, 4096).read_line!()?

	(outbox, deliveries) = Channel.new!(64)?
	Task.spawn!(|| {
		while True {
			match deliveries.receive!() {
				Ok(line) => stream.write_str!("${line}\n")?
				Err(ChannelClosed) => break
			}
		}
		Ok({})
	})?
	hub.send!(Join({ id, name: if Str.is_empty(Str.trim(name)) "anonymous" else Str.trim(name), outbox }))?

	result = reader.each_line!(|line|
		match line {
			"/quit" => Ok(Stop)
			"/who" => hub.send!(Who(id)).map_ok(|_| Continue)
			_ => hub.send!(Say(id, line)).map_ok(|_| Continue)
		})
	# Leave even if the connection failed, so the hub forgets this user.
	hub.send!(Leave(id))?
	match result {
		# Closing a chat window abruptly is a normal way to leave.
		Err(TcpErr(ConnectionReset)) => Ok({})
		other => other
	}
}
