import Host
import Time

## Bounded channels for sending values between tasks.
##
## ```roc
## (tx, rx) = Channel.new!(16)?
## _ = Task.spawn!(|| tx.send!("hello from a task"))
## greeting = rx.receive!()?
## ```
##
## A channel holds up to its capacity of values: `send!` waits while it's
## full and `receive!` waits while it's empty. Any number of tasks can share
## either end. Values of any type can be sent, including sockets and other
## channels' ends.
##
## Ends close automatically once nothing refers to them: after their last
## use, and at the latest when the function or task holding them returns.
## (Don't rely on the exact moment within a function; call `close!` to close
## at a specific point.) When the sender is
## gone (or `close!` is called), receivers get the values already queued and
## then `ChannelClosed`, which is how a receiving loop learns to stop. When the
## receiver is gone, `send!` fails with `ChannelClosed` rather than waiting
## forever, and any queued values are dropped.
Channel := [].{

	## The sending end of a channel carrying values of type `a`.
	Sender(a) :: Host.ChannelEnd.{

		## Queue `value`, waiting while the channel is full. Fails with
		## `Cancelled` if the task is cancelled while waiting.
		send! : Sender(a), a => Try({}, [ChannelClosed, Cancelled])
		send! = |Sender.(end), value|
			match Host.channel_send!(end, Box.box(|| value), True) {
				Sent => Ok({})
				# send! waits for room, so Full doesn't happen.
				Full | Closed => Err(ChannelClosed)
				Cancelled => Err(Cancelled)
			}

		## Queue `value` if there's room right now; otherwise fail with
		## `ChannelFull` instead of waiting.
		try_send! : Sender(a), a => Try({}, [ChannelFull, ChannelClosed])
		try_send! = |Sender.(end), value|
			match Host.channel_send!(end, Box.box(|| value), False) {
				Sent => Ok({})
				Full => Err(ChannelFull)
				Closed => Err(ChannelClosed)
				# try_send! never waits, so it can't be cancelled.
				Cancelled => Err(ChannelFull)
			}

		## Stop sending: receivers get the values already queued, then
		## `ChannelClosed`, and later sends fail. Dropping every copy of the
		## sender has the same effect.
		close! : Sender(a) => {}
		close! = |Sender.(end)| Host.channel_close!(end)

		## The host channel end, for `Select` to wait on.
		channel_end : Sender(a) -> Host.ChannelEnd
		channel_end = |Sender.(end)| end
	}

	## The receiving end of a channel carrying values of type `a`.
	Receiver(a) :: Host.ChannelEnd.{

		## Take the next value, waiting as long as it takes. Fails with
		## `ChannelClosed` once the channel is closed and empty, or
		## `Cancelled` if the task is cancelled while waiting.
		receive! : Receiver(a) => Try(a, [ChannelClosed, Cancelled])
		receive! = |Receiver.(end)|
			match Host.channel_receive!(end, U64.highest) {
				Ok(boxed) => Ok(unwrap(boxed))
				Err(Cancelled) => Err(Cancelled)
				Err(_) => Err(ChannelClosed)
			}

		## Take the next value, waiting at most `timeout`.
		receive_timeout! : Receiver(a), Time.Duration => Try(a, [ChannelClosed, TimedOut, Cancelled])
		receive_timeout! = |Receiver.(end), timeout|
			match Host.channel_receive!(end, timeout.to_nanos()) {
				Ok(boxed) => Ok(unwrap(boxed))
				Err(Closed) => Err(ChannelClosed)
				Err(TimedOut) => Err(TimedOut)
				Err(Cancelled) => Err(Cancelled)
			}

		## Take the next value if one is queued right now, without waiting.
		try_receive! : Receiver(a) => Try(a, [ChannelEmpty, ChannelClosed])
		try_receive! = |Receiver.(end)|
			match Host.channel_receive!(end, 0) {
				Ok(boxed) => Ok(unwrap(boxed))
				Err(Closed) => Err(ChannelClosed)
				# A zero timeout never waits, so it can't be cancelled either.
				Err(TimedOut) | Err(Cancelled) => Err(ChannelEmpty)
			}

		## The host channel end, for `Select` to wait on.
		channel_end : Receiver(a) -> Host.ChannelEnd
		channel_end = |Receiver.(end)| end
	}

	## A new channel that holds up to `capacity` values (at least 1). Fails if
	## `ROC_NET_MAX_CHANNELS` channels (default 8,192) already exist.
	new! : U64 => Try((Sender(a), Receiver(a)), [TooManyChannels])
	new! = |capacity|
		match Host.channel_new!(capacity) {
			Ok(ends) => Ok((Sender.(ends.sender), Receiver.(ends.receiver)))
			Err(TooManyChannels) => Err(TooManyChannels)
		}

	unwrap : Box(() -> a) -> a
	unwrap = |boxed| {
		thunk = Box.unbox(boxed)
		thunk()
	}
}
