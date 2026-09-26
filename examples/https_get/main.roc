app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Framing
import pf.Stdout
import pf.Tls

# Demonstrates: Tls.connect!, reading an HTTP response with Framing
#
# Usage: https_get URL
#   https_get https://example.com/
#   https_get https://www.rust-lang.org/robots.txt
#
# Prints the status line and headers, then the body. Uses HTTP/1.0 so the
# server sends the body as-is and closes the connection when it's done,
# which keeps this example free of HTTP/1.1's chunked encoding.

main! : List(Str) => Try({}, _)
main! = |args| {
	(host, port, path) =
		match args {
			[_, url] =>
				match parse_url(url) {
					Ok(parts) => parts
					Err(_) => return usage!()
				}
			_ => return usage!()
		}

	stream =
		match Tls.connect!("${host}:${port}") {
			Ok(s) => s
			Err(TlsErr(Other(message))) => {
				Stdout.line!("TLS failed: ${message}")?
				return Err(Exit(1))
			}
			Err(err) => return Err(err)
		}
	stream.write_str!("GET ${path} HTTP/1.0\r\nHost: ${host}\r\nUser-Agent: roc-net https_get\r\nAccept: */*\r\n\r\n")?

	# The head is lines up to a blank one; the body is everything after.
	(status, reader) = Framing.reader(stream).read_line!()?
	Stdout.line!(status)?
	var $reader = reader
	var $content_length = Err(NotContentLength)
	while True {
		(header, $reader) = $reader.read_line!()?
		if Str.is_empty(header) {
			break
		}
		Stdout.line!(header)?
		match content_length(header) {
			Ok(n) => {
				$content_length = Ok(n)
			}
			Err(_) => {}
		}
	}
	Stdout.line!("")?

	# Many servers close without ending the TLS session properly. With a
	# Content-Length we can check the body is complete ourselves, so that's
	# safe to allow; without one, the body runs until the connection closes,
	# and a missing ending could hide a cut-off body, so we say so.
	stream.ignore_unexpected_eof!(True)?
	body =
		match $content_length {
			Ok(length) => {
				(bytes, _) = $reader.read_exactly!(length)?
				bytes
			}
			Err(_) => {
				Stdout.line!("(no Content-Length: reading until the server closes the connection)")?
				(bytes, _) = $reader.read_to_end!()?
				bytes
			}
		}
	Stdout.line!(Str.from_utf8_lossy(body))
}

## The value of a `Content-Length` header line, if that's what it is.
content_length : Str -> Try(U64, [NotContentLength])
content_length = |header|
	match Str.split_first(header, ":") {
		Ok({ before, after }) if ascii_lower(before) == "content-length" =>
			match U64.from_str(Str.trim(after)) {
				Ok(n) => Ok(n)
				Err(_) => Err(NotContentLength)
			}
		_ => Err(NotContentLength)
	}

ascii_lower : Str -> Str
ascii_lower = |text|
	Str.from_utf8_lossy(Str.to_utf8(text).map(|b| if b >= 65 and b <= 90 b + 32 else b))

usage! = || {
	Stdout.line!("Usage: https_get https://HOST[:PORT][/PATH]")?
	Err(Exit(2))
}

parse_url : Str -> Try((Str, Str, Str), [BadUrl])
parse_url = |url| {
	rest =
		if Str.starts_with(url, "https://") {
			Str.drop_prefix(url, "https://")
		} else {
			return Err(BadUrl)
		}
	(authority, path) =
		match Str.split_first(rest, "/") {
			Ok({ before, after }) => (before, "/${after}")
			Err(_) => (rest, "/")
		}
	(host, port) =
		match Str.split_first(authority, ":") {
			Ok({ before, after }) => (before, after)
			Err(_) => (authority, "443")
		}
	if Str.is_empty(host) Err(BadUrl) else Ok((host, port, path))
}
