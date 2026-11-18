#!/bin/bash
# Called by the keycloak service entrypoint in docker-compose.yml.
# Master realm sslRequired defaults to EXTERNAL, so a public HTTP host
# shows "HTTPS required". This sets it to NONE after the server is up.
set -eu

/opt/keycloak/bin/kc.sh start-dev \
  --import-realm \
  --https-certificate-file=/opt/keycloak/certs/server.crt \
  --https-certificate-key-file=/opt/keycloak/certs/server.key &
child=$!

term() {
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
}
trap term TERM INT

i=0
while [ "$i" -lt 90 ]; do
  if /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://127.0.0.1:8080 \
      --realm master \
      --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
      --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"; then
    /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE
    echo "Master realm sslRequired set to NONE"
    break
  fi
  i=$((i + 1))
  sleep 2
done

wait "$child"
