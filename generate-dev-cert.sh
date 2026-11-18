#!/bin/sh
# Local TLS certificate so Keycloak's issuer and JWKS URL are https.
# The SMART authorizer refuses an http JWKS URL.
set -eu
dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
mkdir -p "$dir/certs"
# Docker creates a missing bind-mount source as a directory.
for f in "$dir/certs/server.crt" "$dir/certs/server.key"; do
  if [ -d "$f" ]; then
    rm -rf "$f"
  fi
done
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$dir/certs/server.key" \
    -out "$dir/certs/server.crt" \
    -days 825 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
chmod a+r "$dir/certs/server.crt" "$dir/certs/server.key"
echo "Wrote $dir/certs/server.crt and server.key"
