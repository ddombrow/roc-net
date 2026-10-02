# Changelog: protobuf

Versioned on its own, separately from roc-net (see the root README). Pure
Roc: no platform needed.

## 0.1.0

The Protocol Buffers wire format, without schemas:

- `Protobuf.encode` and `Protobuf.decode`, between bytes and a message's
  fields (field number, value).
- A constructor per protobuf type (`int32`, `sint64`, `fixed32`, `double`,
  `string`, `message`, `packed`, ...) and a reader per type (`as_int32`,
  `as_string`, `as_message`, ...).
- Protobuf's reading rules: `last` (and `get`) for a scalar field (the last
  one sent counts), `repeated` and `repeated_varints` / `repeated_fixed32` /
  `repeated_fixed64` for repeated fields, packed or not.
- Checked against protoc's encodings of every scalar type, packed and
  unpacked repeated fields, nested messages and the highest field number
  (`testdata/`).
