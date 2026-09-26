app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Dns
import pf.Stdout
import pf.Tcp
import pf.Time

# Demonstrates: Dns.resolve!, Time.now!/sleep!, timing TCP handshakes
#
# Usage: tcp_ping HOST [PORT] [-c COUNT] [-i INTERVAL_MS] [-t TIMEOUT_MS]
#   tcp_ping example.com 443
#   tcp_ping 127.0.0.1 22 -c 10 -i 200
#
# Like ping, but instead of an ICMP echo it times opening a TCP connection
# (SYN, then SYN-ACK) to PORT, then closes it. That works where ICMP is
# blocked, and shows whether the service is accepting connections: a closed
# port answers "refused", and a firewall that drops packets shows timeouts.

Options : { host : Str, port : Str, count : U64, interval_ms : U64, timeout_ms : U64 }

main! : List(Str) => Try({}, _)
main! = |args| {
	opts =
		match parse_args(List.drop_first(args, 1), { host: "", port: "80", count: 4, interval_ms: 1000, timeout_ms: 2000 }) {
			Ok(parsed) if parsed.host != "" => parsed
			_ => {
				Stdout.line!("Usage: tcp_ping HOST [PORT] [-c COUNT] [-i INTERVAL_MS] [-t TIMEOUT_MS]")?
				return Err(Exit(2))
			}
		}

	# Resolve once, so name lookups don't count toward the timings.
	ip =
		match Dns.resolve!(opts.host) {
			Ok([first, ..]) => first
			_ => {
				Stdout.line!("tcp_ping: cannot resolve ${opts.host}")?
				return Err(Exit(2))
			}
		}
	target = if Str.contains(ip, ":") "[${ip}]:${opts.port}" else "${ip}:${opts.port}"
	Stdout.line!("TCP ping ${opts.host} (${ip}) port ${opts.port}")?

	var $times = []
	for seq in U64.until(0, opts.count) {
		start = Time.now!()
		outcome = Tcp.connect_timeout!(target, Millis(opts.timeout_ms))
		took = start.elapsed!()
		line =
			match outcome {
				Ok(_stream) => {
					$times = List.append($times, took.to_micros())
					"connected to ${target}: seq=${seq.to_str()} time=${format_ms(took.to_micros())} ms"
				}
				Err(TcpErr(ConnectionRefused)) =>
					"refused by ${target} (port closed): seq=${seq.to_str()} time=${format_ms(took.to_micros())} ms"
				Err(TcpErr(TimedOut)) =>
					"no response from ${target}: seq=${seq.to_str()} (timed out after ${opts.timeout_ms.to_str()} ms)"
				Err(TcpErr(err)) =>
					"failed to connect to ${target}: seq=${seq.to_str()} ${Str.inspect(err)}"
			}
		Stdout.line!(line)?
		if seq + 1 < opts.count {
			# Keep a steady pace: wait out whatever the attempt didn't use.
			Time.sleep!(Time.millis(opts.interval_ms).minus(took))
		}
	}

	print_summary!(opts, $times)
}

print_summary! = |opts, times| {
	connected = List.len(times)
	failed_pct = (opts.count - connected) * 100 // opts.count
	Stdout.line!("\n--- ${opts.host}:${opts.port} tcp ping statistics ---")?
	Stdout.line!("${opts.count.to_str()} attempts, ${connected.to_str()} connected, ${failed_pct.to_str()}% failed")?
	if connected == 0 {
		return Err(Exit(1))
	}
	stats = summarize(times)
	Stdout.line!("round-trip min/avg/max/stddev = ${format_ms(stats.min)}/${format_ms(stats.avg)}/${format_ms(stats.max)}/${format_ms(stats.stddev)} ms")
}

## Min, average, max, and (population) standard deviation, in microseconds.
summarize : List(U64) -> { min : U64, avg : U64, max : U64, stddev : U64 }
summarize = |times| {
	n = List.len(times).to_f64()
	min = List.fold(times, U64.highest, |acc, t| if t < acc t else acc)
	max = List.fold(times, 0, |acc, t| if t > acc t else acc)
	mean = List.fold(times, 0.0, |acc, t| acc + t.to_f64()) / n
	variance = List.fold(times, 0.0, |acc, t| acc + (t.to_f64() - mean) * (t.to_f64() - mean)) / n
	{ min, avg: round(mean), max, stddev: round(F64.sqrt(variance)) }
}

round : F64 -> U64
round = |x| (x + 0.5).to_u64_wrap()

## 8742 microseconds becomes "8.742".
format_ms : U64 -> Str
format_ms = |us| {
	fraction = (us % 1000).to_str()
	"${(us // 1000).to_str()}.${Str.repeat("0", 3 - Str.count_utf8_bytes(fraction))}${fraction}"
}

parse_args : List(Str), Options -> Try(Options, [BadArgs])
parse_args = |args, opts|
	match args {
		[] => Ok(opts)
		["-c", n, .. as rest] => parse_args(rest, { ..opts, count: number(n)? })
		["-i", n, .. as rest] => parse_args(rest, { ..opts, interval_ms: number(n)? })
		["-t", n, .. as rest] => parse_args(rest, { ..opts, timeout_ms: number(n)? })
		[value, .. as rest] =>
			if opts.host == "" {
				parse_args(rest, { ..opts, host: value })
			} else {
				parse_args(rest, { ..opts, port: value })
			}
	}

number : Str -> Try(U64, [BadArgs])
number = |text|
	match U64.from_str(text) {
		Ok(n) if n > 0 => Ok(n)
		_ => Err(BadArgs)
	}
