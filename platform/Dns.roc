import Host
import IOErr

## Look up host names with the operating system's resolver, the same one
## `Tcp.connect!` uses for names like `"example.com:80"`.
##
## To query specific record types (MX, TXT, ...) or a chosen DNS server, see
## `examples/dns_client`, which speaks the DNS protocol itself over UDP.
Dns := [].{

	## The IP addresses `name` resolves to, such as `["93.184.215.14"]` for
	## `"example.com"`, giving up after 30 seconds. IPv6 addresses come back
	## without brackets. Fails with `DnsErr(NotFound)` if the name has no
	## addresses, `DnsErr(TimedOut)` if the lookup takes too long, and usually
	## `DnsErr(Other(...))` with the resolver's message if the name doesn't
	## exist.
	resolve! : Str => Try(List(Str), [DnsErr(IOErr)])
	resolve! = |name| resolve_timeout!(name, Millis(30000))

	## Like `resolve!`, giving up with `DnsErr(TimedOut)` after `timeout`.
	##
	## The system resolver can't be interrupted, so a lookup that times out
	## carries on in the background until the resolver itself gives up, and
	## this returns without waiting for it. At most 64 such lookups run at
	## once; past that, new lookups fail with `TimedOut` straight away.
	resolve_timeout! : Str, [Millis(U64)] => Try(List(Str), [DnsErr(IOErr)])
	resolve_timeout! = |name, Millis(ms)|
		# 0 would mean "no timeout" to the host, so round up.
		match Host.dns_resolve!(name, if ms == 0 1 else ms) {
			Ok(addresses) => Ok(addresses)
			Err(err) => Err(DnsErr(err))
		}
}
