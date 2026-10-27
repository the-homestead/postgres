#!/bin/sh
set -e
# entrypoint.sh — Dynamically configures shared_preload_libraries, pgBackRest,
# and scheduled backups based on ENABLE_* environment variables before
# handing off to the official postgres docker-entrypoint.

##############################################################################
# Helpers
##############################################################################

_add_preload() { PRELOAD_LIBS="${PRELOAD_LIBS:+${PRELOAD_LIBS},}$1"; }

_upsert_conf() {
    local file="$1" key="$2" value="$3"
    [ -f "$file" ] || return 0
    if grep -q "^${key}" "$file"; then
        sed -i "s|^${key}.*|${key} = ${value}|" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

##############################################################################
# 0. Derived defaults — computed once from known env vars so extensions
#    that need them don't require the user to manually wire things up.
##############################################################################

# pg_cron: which database the background worker reads jobs from.
# Default to 'postgres' (pg_cron's own default) so the extension always
# installs cleanly in the standard database. Override with PGCRON_DATABASE.
PGCRON_DATABASE="${PGCRON_DATABASE:-postgres}"

# pg_later: needs a libpq connection string to the database where pgmq lives.
# Auto-construct from the standard postgres env vars if not explicitly set.
# Users can override by setting DATABASE_URL themselves.
if [ -z "${DATABASE_URL}" ] && [ "${ENABLE_PGLATER:-true}" = "true" ]; then
    _PG_USER="${POSTGRES_USER:-postgres}"
    _PG_PASS="${POSTGRES_PASSWORD:-}"
    _PG_DB="${POSTGRES_DB:-postgres}"
    _PG_HOST="${POSTGRES_HOST:-localhost}"
    _PG_PORT="${POSTGRES_PORT:-5432}"
    if [ -n "${_PG_PASS}" ]; then
        DATABASE_URL="postgresql://${_PG_USER}:${_PG_PASS}@${_PG_HOST}:${_PG_PORT}/${_PG_DB}"
    else
        DATABASE_URL="postgresql://${_PG_USER}@${_PG_HOST}:${_PG_PORT}/${_PG_DB}"
    fi
    export DATABASE_URL
    echo ">>> Auto-configured DATABASE_URL for pg_later (host=${_PG_HOST} db=${_PG_DB})"
fi

##############################################################################
# 1. Build shared_preload_libraries dynamically
##############################################################################
PRELOAD_LIBS=""

# Order matters: timescaledb must be first when present.
[ "${ENABLE_TIMESCALEDB:-true}" = "true" ] && _add_preload "timescaledb"
[ "${ENABLE_PGCRON:-true}"      = "true" ] && _add_preload "pg_cron"
[ "${ENABLE_SAFEUPDATE:-true}"  = "true" ] && _add_preload "safeupdate"
[ "${ENABLE_PGAUDIT:-true}"     = "true" ] && _add_preload "pgaudit"
[ "${ENABLE_PGSQUEEZE:-true}"   = "true" ] && _add_preload "pg_squeeze"
[ "${ENABLE_PGLATER:-true}"     = "true" ] && _add_preload "pg_later"
[ "${ENABLE_ANON:-true}"        = "true" ] && _add_preload "anon"

echo ">>> shared_preload_libraries will be: '${PRELOAD_LIBS}'"

# ── Update postgresql.conf.sample (used by initdb on first run) ──────────────
CONF_SAMPLE=/usr/share/postgresql/postgresql.conf.sample
if [ -f "${CONF_SAMPLE}" ]; then
    sed -i "s|^shared_preload_libraries.*||g" "${CONF_SAMPLE}"
    echo "shared_preload_libraries='${PRELOAD_LIBS}'" >> "${CONF_SAMPLE}"

    if [ "${ENABLE_PGCRON:-true}" = "true" ]; then
        grep -q "^cron.database_name" "${CONF_SAMPLE}" || \
            echo "cron.database_name='${PGCRON_DATABASE}'" >> "${CONF_SAMPLE}"
    fi

    if [ "${ENABLE_PGBACKREST:-true}" = "true" ]; then
        grep -q "^archive_mode"    "${CONF_SAMPLE}" || echo "archive_mode = on"                                               >> "${CONF_SAMPLE}"
        grep -q "^archive_command" "${CONF_SAMPLE}" || echo "archive_command = 'pgbackrest --stanza=default archive-push %p'" >> "${CONF_SAMPLE}"
        grep -q "^archive_timeout" "${CONF_SAMPLE}" || echo "archive_timeout = 1800"                                         >> "${CONF_SAMPLE}"
    else
        sed -i "s|^archive_mode.*|archive_mode = off|g" "${CONF_SAMPLE}"
    fi
fi

# ── Also update an existing PGDATA/postgresql.conf (volume-reuse path) ───────
PGDATA="${PGDATA:-/var/lib/postgresql/${POSTGRESQL_VERSION:-18}/docker}"
if [ -f "${PGDATA}/postgresql.conf" ]; then
    echo ">>> Existing PGDATA detected — patching postgresql.conf in-place..."
    sed -i "s|^shared_preload_libraries.*||g" "${PGDATA}/postgresql.conf"
    echo "shared_preload_libraries='${PRELOAD_LIBS}'" >> "${PGDATA}/postgresql.conf"

    if [ "${ENABLE_PGCRON:-true}" = "true" ]; then
        _upsert_conf "${PGDATA}/postgresql.conf" "cron.database_name" "'${PGCRON_DATABASE}'"
    fi

    if [ "${ENABLE_PGBACKREST:-true}" = "true" ]; then
        _upsert_conf "${PGDATA}/postgresql.conf" "archive_mode"    "on"
        _upsert_conf "${PGDATA}/postgresql.conf" "archive_command" "'pgbackrest --stanza=default archive-push %p'"
        _upsert_conf "${PGDATA}/postgresql.conf" "archive_timeout" "1800"
    else
        _upsert_conf "${PGDATA}/postgresql.conf" "archive_mode" "off"
    fi
fi

##############################################################################
# 2. pgBackRest config + cron
##############################################################################
PGBACKREST_CONFIG="${PGBACKREST_CONFIG:-/etc/pgbackrest/pgbackrest.conf}"
export PGBACKREST_CONFIG
PGBACKREST_MANAGE_CONFIG="${PGBACKREST_MANAGE_CONFIG:-1}"
PGBACKREST_MANAGE_CRON="${PGBACKREST_MANAGE_CRON:-1}"
PGBACKREST_CRON_FILE="${PGBACKREST_CRON_FILE:-/etc/cron.d/pgbackrest}"

if [ "${ENABLE_PGBACKREST:-true}" = "true" ]; then
    umask 0077
    mkdir -p "$(dirname "${PGBACKREST_CONFIG}")"

    if [ "${PGBACKREST_MANAGE_CONFIG}" = "1" ]; then
        cat > "${PGBACKREST_CONFIG}" <<__EOT__
[global]
spool-path=/pgbackrest/spool

start-fast=y
delta=y
expire-auto=y

compress-type=zst
compress-level=6

log-level-console=info
log-level-file=detail

repo1-retention-full=${PGBACKREST_RETENTION_FULL:-13}
repo1-path=/pgbackrest/repo
__EOT__

        if [ -n "${PGBR_S3_ENDPOINT}" ]; then
            echo ">>> S3 endpoint detected — configuring pgBackRest for S3."
            [ -z "${PGBR_S3_KEY}"        ] && { echo "ERROR: PGBR_S3_KEY is not set."        >&2; exit 1; }
            [ -z "${PGBR_S3_BUCKET}"     ] && { echo "ERROR: PGBR_S3_BUCKET is not set."     >&2; exit 1; }
            [ -z "${PGBR_S3_KEY_SECRET}" ] && { echo "ERROR: PGBR_S3_KEY_SECRET is not set." >&2; exit 1; }
            cat >> "${PGBACKREST_CONFIG}" <<__EOT__

archive-async=y
process-max=2

repo1-type=s3
repo1-s3-uri-style=path
repo1-s3-region=${PGBR_S3_REGION:-us-east-1}
repo1-s3-endpoint=${PGBR_S3_ENDPOINT}
repo1-s3-bucket=${PGBR_S3_BUCKET}
repo1-s3-key=${PGBR_S3_KEY}
repo1-s3-key-secret=${PGBR_S3_KEY_SECRET}
repo1-s3-verify-ssl=n
__EOT__
        else
            echo ">>> No S3 endpoint — configuring pgBackRest for local disk."
            cat >> "${PGBACKREST_CONFIG}" <<__EOT__

archive-async=n
process-max=4

repo1-type=posix
__EOT__
        fi

        cat >> "${PGBACKREST_CONFIG}" <<__EOT__

[default]
pg1-path=${PGDATA}
__EOT__
    else
        echo ">>> Reusing existing pgBackRest config at ${PGBACKREST_CONFIG}"
    fi

    PGBACKREST_CRON_FULL="${PGBACKREST_CRON_FULL:-5 2 * * 0}"
    PGBACKREST_CRON_INCR="${PGBACKREST_CRON_INCR:-5 2 * * 1-6}"

    if [ "${PGBACKREST_MANAGE_CRON}" = "1" ]; then
        echo ">>> Writing backup cron schedule to ${PGBACKREST_CRON_FILE}..."
        cat > "${PGBACKREST_CRON_FILE}" <<__EOF__
# Full backup every Sunday at 02:05
${PGBACKREST_CRON_FULL} su - postgres -c "pgbackrest --stanza=default --type=full backup --log-level-console=info"

# Incremental backup Mon–Sat at 02:05
${PGBACKREST_CRON_INCR} su - postgres -c "pgbackrest --stanza=default --type=incr backup --log-level-console=info"
__EOF__
        chmod 0644 "${PGBACKREST_CRON_FILE}"
    fi

    echo ">>> Starting supercronic scheduler..."
    /usr/local/bin/supercronic "${PGBACKREST_CRON_FILE}" &

    (
        while ! pg_isready -q -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"; do
            sleep 3
        done
        echo ">>> Ensuring pgBackRest stanza 'default' exists..."
        su - postgres -c \
            "pgbackrest --config=${PGBACKREST_CONFIG} --stanza=default --log-level-stderr=info stanza-create" || true
    ) &
else
    echo ">>> pgBackRest is disabled — skipping config, cron, and supercronic."
fi

unset PGBACKREST_CRON_FULL PGBACKREST_CRON_INCR

# Add certificate files
echo "$SERVER_CRT" > /var/lib/postgresql/server.crt
echo "$SERVER_KEY" > /var/lib/postgresql/server.key
echo "$ROOT_CA_CRT" > /var/lib/postgresql/rootCA.crt

# Update file permissions of certificates
chmod 600 /var/lib/postgresql/server.* /var/lib/postgresql/rootCA.crt
chown postgres:postgres /var/lib/postgresql/server.* /var/lib/postgresql/rootCA.crt


##############################################################################
# 3. Hand off to the official postgres docker-entrypoint
##############################################################################
echo ">>> Starting PostgreSQL..."
exec /usr/local/bin/docker-entrypoint.sh "$@"