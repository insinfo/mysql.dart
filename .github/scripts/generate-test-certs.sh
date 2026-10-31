#!/usr/bin/env bash
# CA and server certificate for the TLS test servers, in certs/.
# The server certificate names localhost and 127.0.0.1 (the driver verifies
# the host) and is valid for 365 days (macOS rejects longer TLS certificates).
set -euo pipefail
mkdir -p certs

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout certs/ca-key.pem -out certs/ca-cert.pem \
  -subj "/C=BR/ST=Rio de Janeiro/L=Rio das Ostras/O=PMRO/OU=ASCOMTI/CN=MyTestCA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl req -newkey rsa:2048 -nodes \
  -keyout certs/server-key.pem -out certs/server-req.pem \
  -subj "/C=BR/ST=Rio de Janeiro/L=Rio das Ostras/O=PMRO/OU=ASCOMTI/CN=localhost"

printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' \
  > certs/server-ext.cnf

openssl x509 -req -days 365 \
  -in certs/server-req.pem \
  -CA certs/ca-cert.pem -CAkey certs/ca-key.pem -CAcreateserial \
  -extfile certs/server-ext.cnf \
  -out certs/server-cert.pem
