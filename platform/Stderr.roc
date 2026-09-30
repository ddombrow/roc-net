import Host

## Utilities for writing to [standard error](https://en.wikipedia.org/wiki/Standard_streams#Standard_error_(stderr)).
##
## For a server's logging, use `Log` instead: `line!` writes synchronously,
## so when whatever reads stderr falls behind, the task waits, and so does
## every task sharing its thread. `Log` never waits.
Stderr := [].{

	## Write the given string to standard error, followed by a newline. Waits
	## until it's written (see above).
	##
	## Returns `Err(StderrErr(message))` if the host cannot write to stderr.
	line! : Str => Try({}, [StderrErr(Str)])
	line! = |message|
		match Host.stderr_line!(message) {
			Ok({}) => Ok({})
			Err(StderrErr(err)) => Err(StderrErr(err))
		}
}
