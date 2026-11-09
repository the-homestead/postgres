#!/bin/sh
set -e
# initdb-pgbackrest.sh — Creates the pgBackRest stanza on first database init.
# Skipped entirely when ENABLE_PGBACKREST=false.

if [ "${ENABLE_PGBACKREST:-true}" != "true" ]; then
    echo ">>> pgBackRest is disabled — skipping stanza creation."
    exit 0
fi

echo ">>> Waiting for PostgreSQL to accept connections..."
while ! pg_isready -q; do
    sleep 3
done

echo ">>> Creating pgBackRest stanza 'default'..."
pgbackrest stanza-create \
    --config="${PGBACKREST_CONFIG:-/etc/pgbackrest/pgbackrest.conf}" \
    --stanza=default \
    --log-level-stderr=info

echo ">>> pgBackRest stanza created successfully."