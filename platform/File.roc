import Host
import IOErr

## Read and write whole files.
##
## Paths are relative to the program's working directory unless they start
## with `/`. Each call opens the file, does its work, and closes it again.
##
## File calls block in the operating system, so they run on helper threads
## while the task waits, and never stall other tasks (at most 64 helper
## threads run at once, shared with DNS lookups). A task cancelled during a
## call stops waiting with `FileErr(Cancelled)`, but the call itself still
## finishes in the background: a write may or may not have happened.
##
## Errors are `FileErr(IOErr)`: `NotFound`, `PermissionDenied`,
## `AlreadyExists` (from `write_new!`), or `Other(...)` with the operating
## system's message (for a directory where a file was expected, say).
##
## ## Permissions
##
## `write_new!` and `write_atomic!` take the new file's permissions as a Unix
## mode: `0o600` for a file only its owner can read and write, such as a
## secret key, or `0o644` for one anyone can read. The process's umask can
## take permissions away, never add them. Files that `write_bytes!` or
## `append_bytes!` create get `0o666`, less the umask (usually `0o644`).
File := [].{

	## The file's contents.
	read_bytes! : Str => Try(List(U8), [FileErr(IOErr)])
	read_bytes! = |path|
		match Host.file_read!(path) {
			Ok(bytes) => Ok(bytes)
			Err(err) => Err(FileErr(err))
		}

	## The file's contents as text. Fails with `BadUtf8` if they aren't valid
	## UTF-8.
	read_utf8! : Str => Try(Str, [FileErr(IOErr), BadUtf8({ problem : Str.Utf8Problem, index : U64 })])
	read_utf8! = |path| {
		bytes = read_bytes!(path)?
		match Str.from_utf8(bytes) {
			Ok(text) => Ok(text)
			Err(BadUtf8(problem)) => Err(BadUtf8(problem))
		}
	}

	## Write `bytes` to the file, creating it or replacing what it held.
	##
	## A program that stops partway through (or a full disk) can leave the
	## file cut short. For files that must always be complete, such as
	## configuration or saved state, use `write_atomic!`.
	write_bytes! : Str, List(U8) => Try({}, [FileErr(IOErr)])
	write_bytes! = |path, bytes| write!(path, bytes, 0, 0o666)

	## `write_bytes!` with text.
	write_utf8! : Str, Str => Try({}, [FileErr(IOErr)])
	write_utf8! = |path, text| write_bytes!(path, Str.to_utf8(text))

	## Add `bytes` to the end of the file, creating it if it doesn't exist.
	## Appends from separate calls, even from other processes, don't
	## interleave within a call's bytes on local file systems.
	append_bytes! : Str, List(U8) => Try({}, [FileErr(IOErr)])
	append_bytes! = |path, bytes| write!(path, bytes, 1, 0o666)

	## `append_bytes!` with text.
	append_utf8! : Str, Str => Try({}, [FileErr(IOErr)])
	append_utf8! = |path, text| append_bytes!(path, Str.to_utf8(text))

	## Create the file with `bytes` and permissions `mode` (see
	## "Permissions" above), failing with `FileErr(AlreadyExists)` if it
	## exists. Checking and creating are one step, so two programs can't
	## both create it. For a secret key, use `0o600`:
	##
	## ```roc
	## File.write_new!("identity.key", key_bytes, 0o600)?
	## ```
	write_new! : Str, List(U8), U32 => Try({}, [FileErr(IOErr)])
	write_new! = |path, bytes, mode| write!(path, bytes, 2, mode)

	## Replace the file with `bytes` all at once, with permissions `mode`:
	## anyone reading it sees either the old contents or the new, never part
	## of either, even if the program or the machine stops partway.
	##
	## This writes a temporary file in the same directory, flushes it to
	## disk, and renames it over `path`. The directory must be writable, and
	## the file's previous permissions are replaced by `mode`.
	write_atomic! : Str, List(U8), U32 => Try({}, [FileErr(IOErr)])
	write_atomic! = |path, bytes, mode| write!(path, bytes, 3, mode)

	## Rename (move) `from` to `to`, replacing `to` if it exists, in one step.
	## Both must be on the same file system.
	rename! : Str, Str => Try({}, [FileErr(IOErr)])
	rename! = |from, to|
		match Host.file_rename!(from, to) {
			Ok({}) => Ok({})
			Err(err) => Err(FileErr(err))
		}

	## Delete the file. Fails with `FileErr(NotFound)` if it doesn't exist.
	delete! : Str => Try({}, [FileErr(IOErr)])
	delete! = |path|
		match Host.file_delete!(path) {
			Ok({}) => Ok({})
			Err(err) => Err(FileErr(err))
		}

	## Whether something exists at `path` (a file, a directory, or anything
	## else). Fails only if that can't be determined, such as for
	## `PermissionDenied`.
	##
	## Checking and then acting leaves a gap in which another program can
	## create or delete the file, so prefer acting and handling the error:
	## reading and catching `NotFound`, or `write_new!` and catching
	## `AlreadyExists`.
	exists! : Str => Try(Bool, [FileErr(IOErr)])
	exists! = |path|
		match Host.file_exists!(path) {
			Ok(found) => Ok(found)
			Err(err) => Err(FileErr(err))
		}

	write! : Str, List(U8), U8, U32 => Try({}, [FileErr(IOErr)])
	write! = |path, bytes, how, mode|
		match Host.file_write!(path, bytes, how, mode) {
			Ok({}) => Ok({})
			Err(err) => Err(FileErr(err))
		}
}
