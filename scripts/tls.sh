#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
prepare_state
require_command openssl
require_command kubectl
install -d -m 700 "${STATE_DIR}/tls"
if [[ ! -s "${STATE_DIR}/tls/server.crt" ]]; then
  umask 077
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
    -keyout "${STATE_DIR}/tls/server.key" -out "${STATE_DIR}/tls/server.crt" \
    -subj '/CN=demo.mtc.test' \
    -addext 'subjectAltName=DNS:demo.mtc.test,DNS:split.mtc.test' \
    -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1
fi
openssl x509 -checkend 0 -noout -in "${STATE_DIR}/tls/server.crt" >/dev/null || fail 'The local demo certificate expired; it was not silently replaced.'
kubectl -n mtc-lab create secret tls mtc-demo-tls \
  --cert="${STATE_DIR}/tls/server.crt" --key="${STATE_DIR}/tls/server.key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log 'Demo TLS certificate prepared. Private key remains in .local and Kubernetes Secret.'
