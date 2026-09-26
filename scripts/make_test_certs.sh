#!/bin/sh
# Generate the TLS test certificates in examples/net_tests/certs/: a CA, and a
# server certificate it signed for "localhost" and 127.0.0.1. For tests only;
# the private keys are committed on purpose.
set -e
dir="$(dirname "$0")/../examples/net_tests/certs"
mkdir -p "$dir" && cd "$dir"
tmp=$(mktemp -d)

openssl ecparam -name prime256v1 -genkey -noout -out ca-key.pem
cat > "$tmp/ca.ext" <<'X'
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
X
openssl req -new -key ca-key.pem -subj "/CN=roc-net test CA" -out "$tmp/ca.csr"
openssl x509 -req -in "$tmp/ca.csr" -signkey ca-key.pem -days 36500 -sha256 -extfile "$tmp/ca.ext" -out ca.pem

openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/server-key-ec.pem"
# PKCS#8, the most widely accepted private key format.
openssl pkcs8 -topk8 -nocrypt -in "$tmp/server-key-ec.pem" -out server-key.pem
cat > "$tmp/server.ext" <<'X'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
authorityKeyIdentifier=keyid
X
openssl req -new -key server-key.pem -subj "/CN=localhost" -out "$tmp/server.csr"
openssl x509 -req -in "$tmp/server.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 36500 -sha256 -extfile "$tmp/server.ext" -out server.pem

rm -rf "$tmp" ca.srl
echo "wrote $(pwd): ca.pem ca-key.pem server.pem server-key.pem"
