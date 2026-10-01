import Host

## Utilities for reading from [standard input](https://en.wikipedia.org/wiki/Standard_streams#Standard_input_(stdin)).
Stdin := [].{

	## Read one line from standard input.
	##
	## The returned string does not include the trailing newline. On EOF this returns
	## an empty string, as it does for an empty line: to tell them apart, use
	## `read_line!`.
	##
	## Returns `Err(StdinErr(message))` if the host cannot read from stdin,
	## or for a line over 1 MiB (see `read_line!`).
	line! : {} => Try(Str, [StdinErr(Str)])
	line! = |{}|
		match Host.stdin_line!({}) {
			Ok(line) => Ok(line)
			Err(StdinErr(err)) => Err(StdinErr(err))
		}

	## Read the next line from standard input, without its line ending
	## (`\n` or `\r\n`): `Line(text)`, or `End` once the input has ended (at
	## Ctrl-D in a terminal, or the end of a file or pipe). An empty line is
	## `Line("")`. Waits without holding up other tasks. After `End`, every
	## later read is `End` too. For a line or something else, whichever comes
	## first, see `Select.on_stdin_line`.
	##
	## ```roc
	## while True {
	##     match Stdin.read_line!({})? {
	##         Line(text) => handle!(text)?
	##         End => break
	##     }
	## }
	## ```
	##
	## A line over 1 MiB (1,048,576 bytes, without its line ending) fails
	## with `LineTooLong`, so input from an untrusted source can't use up the
	## program's memory; the rest of that line is skipped, and the next read
	## gets the line after it.
	read_line! : {} => Try([Line(Str), End], [StdinErr(Str), LineTooLong])
	read_line! = |{}|
		match Host.stdin_read_line!({}) {
			Line(text) => Ok(Line(text))
			End => Ok(End)
			TooLong => Err(LineTooLong)
			Failed(err) => Err(StdinErr(err))
		}
}
