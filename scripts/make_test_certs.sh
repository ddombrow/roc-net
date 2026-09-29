#!/bin/sh
# Generate the TLS test certificates in examples/net_tests/certs/: a CA, and
# server certificates it signed: server.pem for "localhost" and 127.0.0.1,
# api.pem for "api.test", and wild.pem for "*.apps.test" (the last two for
# choosing a certificate by name). Files that already exist are kept, so a
# new certificate can be added without replacing the others; delete the
# directory to start over. For tests only; the private keys are committed on
# purpose.
set -e
dir="$(dirname "$0")/../examples/net_tests/certs"
mkdir -p "$dir" && cd "$dir"
tmp=$(mktemp -d)

if [ ! -f ca.pem ]; then
	openssl ecparam -name prime256v1 -genkey -noout -out ca-key.pem
	cat > "$tmp/ca.ext" <<'X'
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
X
	openssl req -new -key ca-key.pem -subj "/CN=roc-net test CA" -out "$tmp/ca.csr"
	openssl x509 -req -in "$tmp/ca.csr" -signkey ca-key.pem -days 36500 -sha256 -extfile "$tmp/ca.ext" -out ca.pem
fi

# issue NAME COMMON_NAME SUBJECT_ALT_NAMES: NAME.pem and NAME-key.pem.
issue() {
	[ -f "$1.pem" ] && return 0
	openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/$1-key-ec.pem"
	# PKCS#8, the most widely accepted private key format.
	openssl pkcs8 -topk8 -nocrypt -in "$tmp/$1-key-ec.pem" -out "$1-key.pem"
	cat > "$tmp/$1.ext" <<X
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=$3
authorityKeyIdentifier=keyid
X
	openssl req -new -key "$1-key.pem" -subj "/CN=$2" -out "$tmp/$1.csr"
	openssl x509 -req -in "$tmp/$1.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 36500 -sha256 -extfile "$tmp/$1.ext" -out "$1.pem"
}

issue server localhost "DNS:localhost,IP:127.0.0.1"
issue api api.test "DNS:api.test"
issue wild "*.apps.test" "DNS:*.apps.test"

rm -rf "$tmp" ca.srl
echo "certificates in $(pwd): $(ls *.pem | tr '\n' ' ')"
