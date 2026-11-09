#!/bin/sh
set -e
# entrypoint.sh — Dynamically configures shared_preload_libraries, pgBackRest,
# and scheduled backups based on ENABLE_* environment variables before
# handing off to the official postgres docker-entrypoint.

##############################################################################
# Helpers
##############################################################################

# Secrets below are written with umask 0077; the original umask is restored
# before the hand-off, or a fresh PGDATA's parent would end up unreadable to
# the postgres user.
ORIGINAL_UMASK=$(umask)

_add_preload() { PRELOAD_LIBS="${PRELOAD_LIBS:+${PRELOAD_LIBS},}$1"; }

# Set `key = value` in a postgresql.conf. Matches the exact key only, so
# setting `ssl` never touches `ssl_cert_file`.
_upsert_conf() {
    _uc_file="$1" _uc_key="$2" _uc_value="$3"
    [ -f "$_uc_file" ] || return 0
    _uc_escaped=$(printf '%s' "$_uc_value" | sed 's/[&|\\]/\\&/g')
    if grep -Eq "^${_uc_key}[[:space:]]*=" "$_uc_file"; then
        sed -i -E "s|^${_uc_key}[[:space:]]*=.*|${_uc_key} = ${_uc_escaped}|" "$_uc_file"
    else
        echo "${_uc_key} = ${_uc_value}" >> "$_uc_file"
    fi
}

##############################################################################
# 0a. Settings that live under PGBR_*
#     pgBackRest treats every PGBACKREST_* environment variable as one of its
#     own options, so the image's settings use PGBR_* instead. The old names
#     still work and are cleared before anything runs pgbackrest.
##############################################################################
PGBR_RETENTION_FULL="${PGBR_RETENTION_FULL:-${PGBACKREST_RETENTION_FULL:-13}}"
PGBR_CRON_FULL="${PGBR_CRON_FULL:-${PGBACKREST_CRON_FULL:-5 2 * * 0}}"
PGBR_CRON_INCR="${PGBR_CRON_INCR:-${PGBACKREST_CRON_INCR:-5 2 * * 1-6}}"
PGBR_MANAGE_CONFIG="${PGBR_MANAGE_CONFIG:-${PGBACKREST_MANAGE_CONFIG:-1}}"
PGBR_MANAGE_CRON="${PGBR_MANAGE_CRON:-${PGBACKREST_MANAGE_CRON:-1}}"
PGBR_CRON_FILE="${PGBR_CRON_FILE:-${PGBACKREST_CRON_FILE:-/etc/cron.d/pgbackrest}}"
unset PGBACKREST_RETENTION_FULL PGBACKREST_CRON_FULL PGBACKREST_CRON_INCR \
      PGBACKREST_MANAGE_CONFIG PGBACKREST_MANAGE_CRON PGBACKREST_CRON_FILE

ARCHIVE_COMMAND="pgbackrest --config=${PGBACKREST_CONFIG:-/etc/pgbackrest/pgbackrest.conf} --stanza=default archive-push %p"

##############################################################################
# 0b. Derived defaults — computed once from known env vars so extensions
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
    _upsert_conf "${CONF_SAMPLE}" "shared_preload_libraries" "'${PRELOAD_LIBS}'"

    if [ "${ENABLE_PGCRON:-true}" = "true" ]; then
        grep -q "^cron.database_name" "${CONF_SAMPLE}" || \
            echo "cron.database_name='${PGCRON_DATABASE}'" >> "${CONF_SAMPLE}"
    fi

    if [ "${ENABLE_PGBACKREST:-true}" = "true" ]; then
        _upsert_conf "${CONF_SAMPLE}" "archive_mode"    "on"
        _upsert_conf "${CONF_SAMPLE}" "archive_command" "'${ARCHIVE_COMMAND}'"
        _upsert_conf "${CONF_SAMPLE}" "archive_timeout" "1800"
    else
        _upsert_conf "${CONF_SAMPLE}" "archive_mode" "off"
    fi
fi

# ── Also update an existing PGDATA/postgresql.conf (volume-reuse path) ───────
PGDATA="${PGDATA:-/var/lib/postgresql/${POSTGRESQL_VERSION:-18}/docker}"
if [ -f "${PGDATA}/postgresql.conf" ]; then
    echo ">>> Existing PGDATA detected — patching postgresql.conf in-place..."
    _upsert_conf "${PGDATA}/postgresql.conf" "shared_preload_libraries" "'${PRELOAD_LIBS}'"

    if [ "${ENABLE_PGCRON:-true}" = "true" ]; then
        _upsert_conf "${PGDATA}/postgresql.conf" "cron.database_name" "'${PGCRON_DATABASE}'"
    fi

    if [ "${ENABLE_PGBACKREST:-true}" = "true" ]; then
        _upsert_conf "${PGDATA}/postgresql.conf" "archive_mode"    "on"
        _upsert_conf "${PGDATA}/postgresql.conf" "archive_command" "'${ARCHIVE_COMMAND}'"
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

if [ "${ENABLE_PGBACKREST:-true}" = "true" ]; then
    # Backups are encrypted unless encryption is switched off on purpose.
    if [ -z "${PGBR_CIPHER_PASS}" ] && [ "${PGBR_ALLOW_UNENCRYPTED:-false}" != "true" ]; then
        echo "ERROR: PGBR_CIPHER_PASS is not set. Backups are encrypted with aes-256-cbc and need a passphrase." >&2
        echo "       Set PGBR_CIPHER_PASS, or PGBR_ALLOW_UNENCRYPTED=true to store backups in the clear." >&2
        exit 1
    fi

    umask 0077
    mkdir -p "$(dirname "${PGBACKREST_CONFIG}")"

    if [ "${PGBR_MANAGE_CONFIG}" = "1" ]; then
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

repo1-retention-full=${PGBR_RETENTION_FULL}
repo1-path=/pgbackrest/repo
__EOT__

        if [ -n "${PGBR_CIPHER_PASS}" ]; then
            cat >> "${PGBACKREST_CONFIG}" <<__EOT__
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=${PGBR_CIPHER_PASS}
__EOT__
        else
            echo ">>> WARNING: PGBR_ALLOW_UNENCRYPTED=true — backups are stored unencrypted." >&2
        fi

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
repo1-s3-verify-tls=${PGBR_S3_VERIFY_TLS:-y}
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
        chown postgres:postgres "${PGBACKREST_CONFIG}"
        chmod 0600 "${PGBACKREST_CONFIG}"
    else
        echo ">>> Reusing existing pgBackRest config at ${PGBACKREST_CONFIG}"
    fi
    unset PGBR_CIPHER_PASS PGBR_S3_KEY PGBR_S3_KEY_SECRET

    if [ "${PGBR_MANAGE_CRON}" = "1" ]; then
        echo ">>> Writing backup cron schedule to ${PGBR_CRON_FILE}..."
        mkdir -p "$(dirname "${PGBR_CRON_FILE}")"
        cat > "${PGBR_CRON_FILE}" <<__EOF__
# Full backup
${PGBR_CRON_FULL} su - postgres -c "pgbackrest --config=${PGBACKREST_CONFIG} --stanza=default --type=full backup --log-level-console=info"

# Incremental backup
${PGBR_CRON_INCR} su - postgres -c "pgbackrest --config=${PGBACKREST_CONFIG} --stanza=default --type=incr backup --log-level-console=info"
__EOF__
        chmod 0644 "${PGBR_CRON_FILE}"
    fi

    echo ">>> Starting supercronic scheduler..."
    /usr/local/bin/supercronic "${PGBR_CRON_FILE}" &

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

unset PGBR_CRON_FULL PGBR_CRON_INCR

##############################################################################
# 3. TLS — only when a certificate and key are supplied
##############################################################################
TLS_DIR=/var/lib/postgresql
if [ -n "${SERVER_CRT}" ] && [ -n "${SERVER_KEY}" ]; then
    echo ">>> TLS material supplied — enabling ssl."
    umask 0077
    printf '%s\n' "${SERVER_CRT}" > "${TLS_DIR}/server.crt"
    printf '%s\n' "${SERVER_KEY}" > "${TLS_DIR}/server.key"
    chmod 600 "${TLS_DIR}/server.crt" "${TLS_DIR}/server.key"
    chown postgres:postgres "${TLS_DIR}/server.crt" "${TLS_DIR}/server.key"

    for f in "${CONF_SAMPLE}" "${PGDATA}/postgresql.conf"; do
        _upsert_conf "$f" "ssl"           "on"
        _upsert_conf "$f" "ssl_cert_file" "'${TLS_DIR}/server.crt'"
        _upsert_conf "$f" "ssl_key_file"  "'${TLS_DIR}/server.key'"
    done

    if [ -n "${ROOT_CA_CRT}" ]; then
        printf '%s\n' "${ROOT_CA_CRT}" > "${TLS_DIR}/rootCA.crt"
        chmod 600 "${TLS_DIR}/rootCA.crt"
        chown postgres:postgres "${TLS_DIR}/rootCA.crt"
        for f in "${CONF_SAMPLE}" "${PGDATA}/postgresql.conf"; do
            _upsert_conf "$f" "ssl_ca_file" "'${TLS_DIR}/rootCA.crt'"
        done
    fi
elif [ -n "${SERVER_CRT}${SERVER_KEY}" ]; then
    echo "ERROR: SERVER_CRT and SERVER_KEY must be set together." >&2
    exit 1
else
    echo ">>> No TLS material supplied — leaving ssl as configured."
fi
unset SERVER_KEY
umask "${ORIGINAL_UMASK}"


##############################################################################
# 4. Hand off to the official postgres docker-entrypoint
##############################################################################
echo ">>> Starting PostgreSQL..."
exec /usr/local/bin/docker-entrypoint.sh "$@"