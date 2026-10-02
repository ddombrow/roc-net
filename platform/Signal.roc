import Host
import IOErr

## Catch signals the operating system sends the program: Ctrl-C in a
## terminal (`Interrupt`), a request to stop from a service manager, a
## container runtime or `kill` (`Terminate`), and the conventional ones for
## reloading configuration (`Hangup`, `User1`, `User2`).
##
## Until a signal is caught it has its usual effect, which for all of these
## is to end the program at once. After `catch!`, it's queued instead, for
## `next!` or a `Select`'s `on_signal` arm, so the program can stop cleanly:
##
## ```roc
## Signal.catch!([Terminate, Interrupt])?
## # ... later, in the accept loop:
## next = Select.new({})
##     .on_accept(listener, |result| Accepted(result))
##     .on_signal(|_| Stop)
##     .wait!()?
## ```
##
## A signal that arrives again while it's still queued counts once. Catching
## can't be undone: once caught, Ctrl-C no longer ends the program unless it
## handles `Interrupt` by stopping.
Signal := [].{

	## The signals that can be caught.
	Kind : [Interrupt, Terminate, Hangup, User1, User2]

	## Start catching `signals`. Catching one already caught does nothing.
	catch! : List(Kind) => Try({}, [SignalErr(IOErr)])
	catch! = |signals|
		match Host.signal_catch!(List.map(signals, code)) {
			Ok({}) => Ok({})
			Err(err) => Err(SignalErr(err))
		}

	## Wait for the next caught signal (see `catch!`), without holding up
	## other tasks. Fails only with `Cancelled`, if the task is cancelled
	## first.
	next! : {} => Try(Kind, [Cancelled])
	next! = |{}|
		match Host.signal_next!({}) {
			Got(c) => Ok(from_code(c))
			Cancelled => Err(Cancelled)
		}

	code : Kind -> U8
	code = |kind|
		match kind {
			Interrupt => 0
			Terminate => 1
			Hangup => 2
			User1 => 3
			User2 => 4
		}

	## For the host's codes (and `Select`).
	from_code : U8 -> Kind
	from_code = |c|
		match c {
			0 => Interrupt
			1 => Terminate
			2 => Hangup
			3 => User1
			_ => User2
		}
}
