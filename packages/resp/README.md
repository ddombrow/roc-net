# resp

The Redis serialization protocol (RESP2 and RESP3), for talking to Redis,
Valkey, KeyDB and other servers that speak it, or for writing one.

```roc
stream = Tcp.connect!("127.0.0.1:6379")?
(reply, reader) = Resp.request!(stream, Framing.reader(stream), ["SET", "k", "v"])?
```

`Resp.parse` reads one value from buffered bytes, so a `Select` can wait
for replies or pushed messages alongside anything else:
`Select.new({}).on_parsed(reader, Resp.parse, |result| ...)`.

The package itself needs no platform; `tests/` uses roc-net to check it
against a server written with it, and (with `just interop-valkey`) against
Valkey. `roc test packages/resp/main.roc` runs the parsing tests.
