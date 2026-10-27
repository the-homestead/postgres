#!/bin/sh
# initdb-extensions.sh — Installs queue and scheduling extensions on first
# database init so their background workers start in a ready state.
#
# pg_later's background worker loops "not ready" until pgmq is installed in
# the target database. pg_cron similarly needs its extension in the configured
# cron.database_name. Installing them here at initdb time means they're ready
# the moment the main postgres process starts.
set -e

export PGUSER="$POSTGRES_USER"

# ── pgmq ──────────────────────────────────────────────────────────────────────
if [ "${ENABLE_PGMQ:-true}" = "true" ]; then
    echo ">>> Installing pgmq in ${POSTGRES_DB}..."
    psql --dbname="${POSTGRES_DB}" -c "CREATE EXTENSION IF NOT EXISTS pgmq;"
fi

# ── pg_later (depends on pgmq) ────────────────────────────────────────────────
if [ "${ENABLE_PGLATER:-true}" = "true" ]; then
    echo ">>> Installing pg_later in ${POSTGRES_DB}..."
    psql --dbname="${POSTGRES_DB}" -c "CREATE EXTENSION IF NOT EXISTS pg_later CASCADE;"
fi

# ── pg_cron ───────────────────────────────────────────────────────────────────
# Must be installed in the database matching cron.database_name (defaults to
# 'postgres'). Using PGCRON_DATABASE so it stays consistent with the entrypoint.
if [ "${ENABLE_PGCRON:-true}" = "true" ]; then
    CRON_DB="${PGCRON_DATABASE:-postgres}"
    echo ">>> Installing pg_cron in ${CRON_DB}..."
    psql --dbname="${CRON_DB}" -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"
fi

echo ">>> Extension initialization complete."