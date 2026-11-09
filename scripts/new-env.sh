#!/usr/bin/env bash
# new-env.sh — write a .env from container/env.example with fresh secrets.
#
# Generates POSTGRES_PASSWORD and PGBR_CIPHER_PASS, writes the file with mode
# 600, and never overwrites an existing file. The secrets are only written to
# the file, never printed.
#
# Usage:
#   scripts/new-env.sh [output]          # default: ./.env
set -euo pipefail

out="${1:-.env}"
example="$(dirname "$0")/../container/env.example"

if [ -e "$out" ]; then
    echo "ERROR: ${out} already exists; not overwriting it." >&2
    exit 1
fi
command -v openssl >/dev/null || {
    echo "ERROR: openssl is required." >&2
    exit 1
}

secret() { openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48; }

umask 077
sed \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(secret)|" \
    -e "s|^PGBR_CIPHER_PASS=.*|PGBR_CIPHER_PASS=$(secret)|" \
    "$example" >"$out"
chmod 600 "$out"

echo ">>> Wrote ${out} (mode 600) with a new POSTGRES_PASSWORD and PGBR_CIPHER_PASS."
echo ">>> Copy PGBR_CIPHER_PASS to your password manager: without it the backups cannot be restored."
