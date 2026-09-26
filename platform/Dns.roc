import Host
import IOErr

## Look up host names with the operating system's resolver, the same one
## `Tcp.connect!` uses for names like `"example.com:80"`.
##
## To query specific record types (MX, TXT, ...) or a chosen DNS server, see
## `examples/dns_client`, which speaks the DNS protocol itself over UDP.
Dns := [].{

	## The IP addresses `name` resolves to, such as `["93.184.215.14"]` for
	## `"example.com"`. IPv6 addresses come back without brackets. Fails with
	## `DnsErr(NotFound)` if the name has no addresses, and usually
	## `DnsErr(Other(...))` with the resolver's message if it doesn't exist.
	resolve! : Str => Try(List(Str), [DnsErr(IOErr)])
	resolve! = |name|
		match Host.dns_resolve!(name) {
			Ok(addresses) => Ok(addresses)
			Err(err) => Err(DnsErr(err))
		}
}
