#!/bin/sh
# update-postgis.sh — Updates PostGIS extensions to the current installed version.
# Skipped when ENABLE_POSTGIS=false.
set -e

if [ "${ENABLE_POSTGIS:-true}" != "true" ]; then
    echo ">>> PostGIS is disabled — skipping update."
    exit 0
fi

export PGUSER="$POSTGRES_USER"
POSTGIS_VERSION="${POSTGIS_VERSION%%+*}"

for DB in template_postgis "${POSTGRES_DB}" "${@}"; do
    echo ">>> Updating PostGIS in '${DB}' to ${POSTGIS_VERSION}..."
    psql --dbname="${DB}" <<-EOSQL
        $( [ "${ENABLE_SAFEUPDATE:-true}" = "true" ] && echo "SET safeupdate.enabled=0;" )

        CREATE EXTENSION IF NOT EXISTS postgis              VERSION '${POSTGIS_VERSION}';
        ALTER  EXTENSION postgis                            UPDATE  TO '${POSTGIS_VERSION}';

        CREATE EXTENSION IF NOT EXISTS postgis_topology     VERSION '${POSTGIS_VERSION}';
        ALTER  EXTENSION postgis_topology                   UPDATE  TO '${POSTGIS_VERSION}';

        CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

        CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder VERSION '${POSTGIS_VERSION}';
        ALTER  EXTENSION postgis_tiger_geocoder               UPDATE  TO '${POSTGIS_VERSION}';

        $( [ "${ENABLE_SAFEUPDATE:-true}" = "true" ] && echo "SET safeupdate.enabled=1;" )
EOSQL
done

echo ">>> PostGIS update complete."