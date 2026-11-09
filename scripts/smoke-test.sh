#!/usr/bin/env bash
# smoke-test.sh — start an image the ways it is used and check each one.
#
# Cases:
#   1. backups on, no passphrase      → the container refuses to start
#   2. backups + TLS on               → ssl on, encrypted full backup, verify ok,
#                                        repository files are ciphertext
#   3. restart of case 2              → every managed setting appears once
#   4. backups + TLS off              → plain start, ssl off, archive_mode off
#
# Usage:
#   scripts/smoke-test.sh <image> [entrypoint-override]
#
# The optional second argument mounts a local entrypoint.sh over the image's,
# so a script change can be tested without rebuilding the image.
set -euo pipefail

if [ $# -lt 1 ]; then
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

image="$1"
override="${2:-}"
prefix="pg-smoke-$$"
workdir="$(mktemp -d)"
cleanup() {
    docker rm -f "${prefix}-tls" "${prefix}-plain" "${prefix}-nopass" >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

pass() { echo "  ✓ $*"; }
fail() {
    echo "  ✗ $*" >&2
    exit 1
}

run_args=(
    -e POSTGRES_PASSWORD=smoke
    -e POSTGRES_DB=smoke
    -e ENABLE_PGLATER=false
    -e ENABLE_SAFEUPDATE=false
    -e ENABLE_POSTGIS=false
)
if [ -n "$override" ]; then
    run_args+=(-v "$(realpath "$override"):/smoke-entrypoint.sh:ro" --entrypoint sh)
    cmd=(/smoke-entrypoint.sh postgres)
else
    cmd=(postgres)
fi

# A fresh cluster logs "ready" twice (the temporary initdb server, then the real
# one); each restart adds one more. Wait until the log has `want` of them.
wait_ready() {
    name="$1" want="${2:-2}"
    for _ in $(seq 1 90); do
        seen="$(docker logs "$name" 2>&1 | grep -c 'database system is ready to accept connections' || true)"
        if [ "$seen" -ge "$want" ] && docker exec "$name" pg_isready -q -U postgres -d smoke 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    docker logs "$name" 2>&1 | tail -40 >&2
    fail "${name} did not become ready"
}

psql_val() { docker exec "$1" psql -U postgres -d smoke -Atc "$2"; }

echo ">>> Case 1: backups on, no passphrase"
if docker run --name "${prefix}-nopass" "${run_args[@]}" -e ENABLE_PGBACKREST=true "$image" "${cmd[@]}" >"$workdir/nopass.log" 2>&1; then
    fail "container started without PGBR_CIPHER_PASS"
fi
grep -q "PGBR_CIPHER_PASS is not set" "$workdir/nopass.log" || fail "missing passphrase error"
pass "refused to start without a passphrase"

echo ">>> Case 2: backups + TLS"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=smoke \
    -keyout "$workdir/server.key" -out "$workdir/server.crt" >/dev/null 2>&1
docker run -d --name "${prefix}-tls" "${run_args[@]}" \
    -e ENABLE_PGBACKREST=true \
    -e PGBR_CIPHER_PASS=smoke-test-passphrase \
    -e PGBACKREST_RETENTION_FULL=2 \
    -e SERVER_CRT="$(cat "$workdir/server.crt")" \
    -e SERVER_KEY="$(cat "$workdir/server.key")" \
    "$image" "${cmd[@]}" >/dev/null
wait_ready "${prefix}-tls"

[ "$(psql_val "${prefix}-tls" 'show ssl')" = on ] || fail "ssl is not on"
pass "ssl on"
[ "$(psql_val "${prefix}-tls" 'show archive_mode')" = on ] || fail "archive_mode is not on"
pass "archive_mode on"

# Wait for the background stanza-create.
for _ in $(seq 1 30); do
    docker logs "${prefix}-tls" 2>&1 | grep -q "stanza-create command end: completed successfully" && break
    sleep 2
done
scripts_dir="$(dirname "$0")"
"$scripts_dir/pgbr.sh" "${prefix}-tls" full --log-level-console=warn || fail "full backup failed"
pass "full backup"
"$scripts_dir/pgbr.sh" "${prefix}-tls" info | grep -q "cipher: aes-256-cbc" || fail "repository is not encrypted"
pass "cipher: aes-256-cbc"
"$scripts_dir/pgbr.sh" "${prefix}-tls" verify --log-level-console=warn || fail "verify failed"
pass "verify"
header="$(docker exec "${prefix}-tls" sh -c 'head -c 8 "$(find /pgbackrest/repo/backup -name "PG_VERSION*" | head -1)"')"
[ "$header" = "Salted__" ] || fail "backup files are not ciphertext"
pass "backup files are ciphertext"
if docker logs "${prefix}-tls" 2>&1 | grep -q "invalid option"; then
    fail "pgBackRest warned about an invalid option"
fi
pass "no invalid-option warnings"

echo ">>> Case 3: restart"
docker restart "${prefix}-tls" >/dev/null
wait_ready "${prefix}-tls" 3
for key in ssl ssl_cert_file ssl_key_file shared_preload_libraries archive_mode archive_command; do
    count="$(docker exec "${prefix}-tls" sh -c "grep -Ec '^${key}[[:space:]]*=' \"\$PGDATA/postgresql.conf\"")"
    [ "$count" = 1 ] || fail "${key} appears ${count} times in postgresql.conf"
done
pass "each managed setting appears once"

echo ">>> Case 4: backups + TLS off"
docker run -d --name "${prefix}-plain" "${run_args[@]}" -e ENABLE_PGBACKREST=false "$image" "${cmd[@]}" >/dev/null
wait_ready "${prefix}-plain"
[ "$(psql_val "${prefix}-plain" 'show ssl')" = off ] || fail "ssl should be off"
[ "$(psql_val "${prefix}-plain" 'show archive_mode')" = off ] || fail "archive_mode should be off"
pass "plain start"

echo ">>> SMOKE TEST PASSED"
