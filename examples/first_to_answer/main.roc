app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Channel
import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Time

# Demonstrates: task handles, cancelling tasks, and scopes
#
# Usage: first_to_answer ADDRESS...
#
# Connects to every address at once and reports the first to accept; the
# other attempts are cancelled rather than left to finish or time out. For
# example, `first_to_answer example.com:443 example.org:443 10.255.255.1:80`
# (the last never answers).

main! : List(Str) => Try({}, _)
main! = |args| {
	addresses = List.drop_first(args, 1)
	if List.is_empty(addresses) {
		_ = Stdout.line!("Usage: first_to_answer ADDRESS...")
		return Err(Exit(2))
	}

	(answers, arrivals) = Channel.new!(List.len(addresses))?
	start = Time.now!()
	# The scope guarantees no attempt is still running once it returns.
	Task.scope!(|scope| {
		var $attempts = []
		for address in addresses {
			attempt = scope.spawn!(|| {
				result = Tcp.connect!(address)
				answers.send!((address, result))
			})?
			$attempts = List.append($attempts, attempt)
		}
		var $failed = 0.U64
		while $failed < List.len(addresses) {
			(address, result) = arrivals.receive!()?
			match result {
				Ok(_stream) => {
					Stdout.line!("${address} answered first, after ${start.elapsed!().to_millis().to_str()} ms")?
					# The rest aren't needed: stop them now.
					for attempt in $attempts {
						attempt.cancel!()
					}
					return Ok({})
				}
				Err(err) => {
					Stdout.line!("${address}: ${Str.inspect(err)}")?
					$failed = $failed + 1
				}
			}
		}
		Stdout.line!("Nobody answered.")
	})
}
