# Changelog: resp

Versioned on its own, separately from roc-net (see the root README). Needs
no platform dependency: its client functions work with any stream that has
`write!` and a reader that has `read_parsed!` (roc-net 0.7's `Framing`).

## 0.1.0

The Redis serialization protocol, RESP2 and RESP3:

- `Resp.Value`, every RESP2 and RESP3 type (maps, sets, pushes, doubles,
  big numbers, verbatim strings, ...); RESP3 attributes are read and dropped.
- `Resp.parse`, in the shape `Framing.Reader.read_parsed!` and
  `Select.on_parsed` take, nested at most 512 levels deep.
- `Resp.encode`, `Resp.command` (and `command_bytes`), and `command_args`
  for servers reading clients' commands.
- `Resp.request!` and `Resp.pipeline!`, generic over the stream and reader.
- Checked against a server written with the package, and against Valkey 8
  (`just interop-valkey`).
