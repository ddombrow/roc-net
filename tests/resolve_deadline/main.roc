app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Dns
import pf.Stdout
import pf.Tcp
import pf.Time
import pf.Tls
import pf.Udp

# Checks that timeouts bound name lookups. Linux containers only: it serves as
# its own DNS server (UDP 127.0.0.1:53, which needs root) that never answers,
# so the container must be set up first (see `just linux-test`):
#
#   /etc/resolv.conf: nameserver 127.0.0.1, options timeout:30 attempts:1
#   /etc/hosts:       multi.roc-net.test -> 10.255.255.1, .2, .3 (unroutable)

main! : List(Str) => Try({}, _)
main! = |_args| {
	# Received and ignored: every lookup through it waits for the resolver's
	# own 30-second timeout, unless ours is shorter.
	silent_dns = Udp.bind!("127.0.0.1:53")?
	results = [
		check!("tcp connect_timeout! covers the name lookup", tcp_lookup!),
		check!("Dns.resolve_timeout! gives up in time", dns_lookup!),
		check!("tls with_timeout covers the name lookup", tls_lookup!),
		check!("several unreachable addresses share one timeout", several_addresses!),
		check!("past 64 slow lookups, more still time out on schedule", pending_cap!),
	]
	# Keep the silent server open until every check is done.
	_ = silent_dns.local_addr!()
	failed = List.len(List.keep_if(results, |passed| !passed))
	if failed == 0 {
		Stdout.line!("All ${List.len(results).to_str()} resolver deadline checks passed")?
		Ok({})
	} else {
		Stdout.line!("${failed.to_str()} of ${List.len(results).to_str()} resolver deadline checks failed")?
		Err(Exit(1))
	}
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

## Run `attempt!`, which must fail with a timeout (as judged by `timed_out`),
## within `timeout_ms` plus a second of slack.
expect_timeout_within! = |timeout_ms, attempt!, timed_out| {
	start = Time.now!()
	result = attempt!()
	took = start.elapsed!().to_millis()
	if !timed_out(result) {
		Err(Unexpected(Str.inspect(result)))
	} else if took < timeout_ms or took > timeout_ms + 1000 {
		Err(Unexpected("timed out after ${took.to_str()} ms, expected about ${timeout_ms.to_str()} ms"))
	} else {
		Ok({})
	}
}

tcp_lookup! = ||
	expect_timeout_within!(
		500,
		|| Tcp.connect_timeout!("slow.roc-net.test:443", Millis(500)),
		|result|
			match result {
				Err(TcpErr(TimedOut)) => True
				_ => False
			},
	)

dns_lookup! = ||
	expect_timeout_within!(
		500,
		|| Dns.resolve_timeout!("slow.roc-net.test", Millis(500)),
		|result|
			match result {
				Err(DnsErr(TimedOut)) => True
				_ => False
			},
	)

tls_lookup! = ||
	expect_timeout_within!(
		500,
		|| Tls.connect_with!("slow.roc-net.test:443", Tls.client_config.with_timeout(Millis(500))),
		|result|
			match result {
				Err(TlsErr(TimedOut)) => True
				_ => False
			},
	)

# /etc/hosts answers at once with three addresses that don't respond. Each
# attempt used to get the full timeout (3 x 600 ms); now they share it.
several_addresses! = ||
	expect_timeout_within!(
		600,
		|| Tcp.connect_timeout!("multi.roc-net.test:443", Millis(600)),
		|result|
			match result {
				Err(TcpErr(TimedOut)) => True
				_ => False
			},
	)

# Each quick lookup times out but leaves its resolver thread waiting on the
# silent server. Once 64 are pending (counting the checks above), new ones
# wait for a free helper thread instead of starting another, and still time
# out on schedule.
pending_cap! = || {
	var $slowest = 0.U64
	for n in U64.until(0, 70) {
		start = Time.now!()
		result = Dns.resolve_timeout!("slow-${n.to_str()}.roc-net.test", Millis(20))
		took = start.elapsed!().to_millis()
		match result {
			Err(DnsErr(TimedOut)) => {
				if took > $slowest {
					$slowest = took
				}
			}
			other => return Err(Unexpected(Str.inspect(other)))
		}
	}
	if $slowest < 500 Ok({}) else Err(Unexpected("a 20 ms lookup took ${$slowest.to_str()} ms"))
}
