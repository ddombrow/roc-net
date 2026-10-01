app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Channel
import pf.Noise
import pf.Select
import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Time
import pf.Tls

# Two tasks Select on one idle stream (Noise, then TLS) for 2 seconds each,
# then exit. Run by scripts/run_net_tests.sh, which checks the CPU time:
# the waits must sleep, not wake each other in a loop (as they once did,
# when every release of the stream's read lock woke every watcher).
main! = |args| {
	_ = args
	idle!(Noise)?
	idle!(Tls)?
	Stdout.line!("Both waits stayed idle")
}

idle! = |kind| {
	waiters = 2
	(keep_tx, keep) = Channel.new!(1)?
	if kind == Noise {
		listener = Tcp.listen!("127.0.0.1:0")?
		address = listener.local_addr!()?
		_ = Task.spawn!(|| {
			tcp = listener.accept!()?
			done = Noise.handshake!(tcp, Noise.config(NN, Responder), [])?
			keep_tx.send!({})?
			Time.sleep!(Time.seconds(10))?
			done.stream.close!()
			Ok({})
		})?
		tcp = Tcp.connect!(address)?
		stream = Noise.handshake!(tcp, Noise.config(NN, Initiator), [])?.stream
		_ = keep.receive!()?
		wait_on!(waiters, || Select.new({}).on_read(stream, 100, |_| Read).on_timeout(Time.seconds(2), || Idle).wait!())
	} else {
		listener = Tls.listen!("127.0.0.1:0", Tls.server_config({ cert_file: "examples/net_tests/certs/server.pem", key_file: "examples/net_tests/certs/server-key.pem" }))?
		address = listener.local_addr!()?
		_ = Task.spawn!(|| {
			stream = listener.accept!()?
			stream.write!([120])?
			keep_tx.send!({})?
			Time.sleep!(Time.seconds(10))?
			stream.close!()
			Ok({})
		})?
		stream = Tls.connect_with!(address, Tls.client_config.with_ca_file("examples/net_tests/certs/ca.pem"))?
		_ = stream.read!(1)?
		_ = keep.receive!()?
		wait_on!(waiters, || Select.new({}).on_read(stream, 100, |_| Read).on_timeout(Time.seconds(2), || Idle).wait!())
	}
}

wait_on! = |waiters, select!| {
	Task.scope!(|scope| {
		var $i = 0
		while $i < waiters.to_u64() {
			$i = $i + 1
			_ = scope.spawn!(|| {
				got = select!()?
				if got != Idle {
					return Err(Unexpected("the idle stream reported data"))
				}
				Ok({})
			})?
		}
		Ok({})
	})
}
