#!/usr/bin/env bash
# generate-certs.sh — create a local CA plus server/client certificates.
#
# The generated files are NOT tracked by git (see ../../.gitignore). The running
# container receives the same material at runtime through the SERVER_CRT,
# SERVER_KEY and ROOT_CA_CRT environment variables, which container/entrypoint.sh
# writes into $PGDATA before starting PostgreSQL.
#
# Usage:
#   ./generate-certs.sh                     # defaults below
#   CA_CN=... SERVER_CN=... ./generate-certs.sh
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

CA_CN="${CA_CN:-homestead.systems.local}"
SERVER_CN="${SERVER_CN:-db.homestead.systems}"
CLIENT_CN="${CLIENT_CN:-infisical}"
SERVER_SAN="${SERVER_SAN:-DNS:${SERVER_CN},DNS:localhost,IP:127.0.0.1}"
DAYS="${DAYS:-365}"
KEY_BITS="${KEY_BITS:-2048}"

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

echo "==> Generating CA: ${CA_CN}"

# ── Root CA ──────────────────────────────────────────────────────────────────
openssl genrsa -out rootCA.key "${KEY_BITS}"
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days "$((DAYS * 2))" \
    -subj "/CN=${CA_CN}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out rootCA.crt

# ── Server certificate ───────────────────────────────────────────────────────
echo "==> Generating server certificate: ${SERVER_CN}"
openssl genrsa -out server.key "${KEY_BITS}"
openssl req -new -key server.key -subj "/CN=${SERVER_CN}" -out server.csr

openssl x509 -req -in server.csr -CA rootCA.crt -CAkey rootCA.key -CAcreateserial \
    -sha256 -days "$DAYS" -out server.crt \
    -extfile <(printf "subjectAltName=%s\n" "${SERVER_SAN}") \
    -extfile <(printf "extendedKeyUsage=serverAuth\n")

# ── Client certificate ───────────────────────────────────────────────────────
echo "==> Generating client certificate: ${CLIENT_CN}"
openssl genrsa -out client.key "${KEY_BITS}"
openssl req -new -key client.key -subj "/CN=${CLIENT_CN}" -out client.csr

openssl x509 -req -in client.csr -CA rootCA.crt -CAkey rootCA.key -CAcreateserial \
    -sha256 -days "$DAYS" -out client.crt \
    -extfile <(printf "extendedKeyUsage=clientAuth\n")

chmod 600 rootCA.key server.key client.key
chmod 644 rootCA.crt server.crt client.crt

# ── Emit the runtime env vars ────────────────────────────────────────────────
echo
echo "==> Add these to your .env (values are quoted for docker-compose):"
printf 'SERVER_CRT="%s"\n' "$(sed ':a;N;$!ba;s/\n/\\n/g' server.crt)"
printf 'SERVER_KEY="%s"\n' "$(sed ':a;N;$!ba;s/\n/\\n/g' server.key)"
printf 'ROOT_CA_CRT="%s"\n' "$(sed ':a;N;$!ba;s/\n/\\n/g' rootCA.crt)"
echo
echo "==> Done. Files in ${DIR}:"
ls -1 "$DIR"
