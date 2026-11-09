#!/usr/bin/env bash
# restore-in-container.sh — runs inside the throwaway restore container.
# Called by scripts/restore-check.sh; not meant to be run directly.
#
# Inputs (environment):
#   BACKUP_SET  backup label to restore; empty for the latest
#   DB_USER     superuser of the restored cluster
#   CHECK_SQL   optional query to run after start-up
# Mounts:
#   /run/restore/pgbackrest.conf  the source container's pgBackRest config
#   /pgbackrest/repo              the repository, read-only
set -euo pipefail

# pgBackRest reads every PGBACKREST_* variable as an option; the image may
# still carry the old cron/retention names, so drop them all.
while IFS= read -r name; do
    unset "$name"
done < <(env | sed -n 's/^\(PGBACKREST_[A-Z_]*\)=.*/\1/p')

pgdata=/tmp/restore
config=/tmp/pgbackrest.conf

install -o postgres -g postgres -m 600 /run/restore/pgbackrest.conf "$config"
install -d -o postgres -g postgres -m 700 "$pgdata"

as_postgres() { su postgres -s /bin/bash -c "$1"; }

set_arg=""
[ -n "${BACKUP_SET:-}" ] && set_arg="--set=${BACKUP_SET}"

as_postgres "pgbackrest --config=${config} --stanza=default --pg1-path=${pgdata} --log-level-console=warn ${set_arg} restore"

# The restored config points at TLS files and an archive this container does
# not have: switch both off and fetch WAL from the repository instead. The
# copied pgbackrest.conf names the source's data directory, so pg1-path is
# set to the restore target here too.
cat >>"${pgdata}/postgresql.auto.conf" <<CONF
ssl = off
archive_mode = off
listen_addresses = ''
restore_command = 'pgbackrest --config=${config} --stanza=default --pg1-path=${pgdata} archive-get %f "%p"'
CONF
chown postgres:postgres "${pgdata}/postgresql.auto.conf"
# Replay every archived WAL segment, then promote.
install -o postgres -g postgres -m 600 /dev/null "${pgdata}/recovery.signal"

if ! as_postgres "pg_ctl -D ${pgdata} -w -t 600 -l /tmp/restore.log start"; then
    cat /tmp/restore.log
    exit 1
fi

# Hot standby accepts connections while WAL is still replaying; wait for the
# replay to finish and the cluster to promote.
promoted=""
for _ in $(seq 1 300); do
    if [ "$(as_postgres "psql -U '${DB_USER}' -d postgres -Atc 'SELECT pg_is_in_recovery()'" 2>/dev/null)" = f ]; then
        promoted=1
        break
    fi
    sleep 2
done
if [ -z "$promoted" ]; then
    echo "ERROR: the restored cluster did not finish recovery within 10 minutes." >&2
    tail -40 /tmp/restore.log >&2
    exit 1
fi

echo ">>> Recovery:"
grep -E "redo done at|last completed transaction|archive recovery complete|selected new timeline" /tmp/restore.log | sed 's/^/    /' || true

echo ">>> Restored cluster is up. Databases:"
as_postgres "psql -U '${DB_USER}' -d postgres -Atc \"SELECT datname || ' ' || pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE NOT datistemplate ORDER BY 1\""

if [ -n "${CHECK_SQL:-}" ]; then
    echo ">>> Check query:"
    printf '%s\n' "$CHECK_SQL" >/tmp/check.sql
    chmod 644 /tmp/check.sql
    as_postgres "psql -U '${DB_USER}' -d postgres -v ON_ERROR_STOP=1 -At -f /tmp/check.sql"
fi

as_postgres "pg_ctl -D ${pgdata} -m fast stop" >/dev/null
