# protobuf

The Protocol Buffers wire format in pure Roc: encode a message's fields to
bytes and decode them back, with no schema compiler. A schema is a pair of
functions on top (see the docs at the top of `Protobuf.roc`).

```roc
app [main!] {
    pf: platform "...",
    pb: "https://gitlab.com/api/v4/projects/86936101/packages/generic/protobuf/0.1.0/<hash>.tar.zst",
}

import pb.Protobuf

bytes = Protobuf.encode([(1, Protobuf.int32(150)), (2, Protobuf.string("hi"))])
```

It needs no platform, so it works in any Roc app. Tests: `roc test
packages/protobuf/main.roc` (also run by `just test`). The vectors they
check against come from protoc: `testdata/make_vectors.sh`.
