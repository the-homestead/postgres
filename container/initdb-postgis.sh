#!/bin/bash
# initdb-postgis.sh — Loads PostGIS extensions on first database init.
# Skipped entirely when ENABLE_POSTGIS=false.
set -e

if [ "${ENABLE_POSTGIS:-true}" != "true" ]; then
    echo ">>> PostGIS is disabled — skipping PostGIS initialization."
    exit 0
fi

export PGUSER="$POSTGRES_USER"

# Helper: disable safeupdate only if it was actually loaded.
_safeupdate_off() {
    [ "${ENABLE_SAFEUPDATE:-true}" = "true" ] && echo "SET safeupdate.enabled=0;" || true
}
_safeupdate_on() {
    [ "${ENABLE_SAFEUPDATE:-true}" = "true" ] && echo "SET safeupdate.enabled=1;" || true
}

echo ">>> Creating template_postgis..."
psql <<-EOSQL
    CREATE DATABASE template_postgis WITH IS_TEMPLATE = true;
EOSQL

for DB in template_postgis "${POSTGRES_DB}"; do
    echo ">>> Loading PostGIS extensions into '${DB}'..."
    psql --dbname="${DB}" <<-EOSQL
        $(_safeupdate_off)
        CREATE EXTENSION IF NOT EXISTS postgis;
        CREATE EXTENSION IF NOT EXISTS postgis_topology;
        \c
        $(_safeupdate_off)
        CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
        CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;
        $(_safeupdate_on)
EOSQL
done

echo ">>> PostGIS initialization complete."