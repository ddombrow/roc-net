#!/bin/sh
# Print the protoc encodings the tests in ../Protobuf.roc compare against,
# as hex. Run it after changing vectors.proto or the messages below, and
# paste the hex into the tests.
set -e
cd "$(dirname "$0")"
encode() {
	printf '%s' "$2" | protoc --proto_path=. --encode="$1" vectors.proto | xxd -p | tr -d '\n'
	echo
}
echo "scalars:"
encode Scalars 'i32: -1 i64: -9223372036854775808 u32: 4294967295 u64: 18446744073709551615 s32: -2147483648 s64: -1 flag: true f32: 7 f64: 18446744073709551615 sf32: -2 sf64: -3 fl: 1.5 db: -0.25 text: "h\303\251llo \342\234\223" data: "\000\001\377"'
echo "collections:"
encode Collections 'packed: [1, 150, -1] unpacked: [3, 270] names: ["a", ""] inner { a: 150 b: "x" } inners { a: 1 } inners { b: "y" } zigzags: [-1, 1, -64] doubles: [1.0, -2.5]'
echo "big field number:"
encode Big 'field_536870911: 1'
echo "empty:"
encode Scalars ''
