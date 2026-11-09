#!/usr/bin/env bash
# pgbr.sh — run pgBackRest inside a running container.
#
# Usage:
#   scripts/pgbr.sh <container> <command> [extra pgbackrest args...]
#
# Commands:
#   info       backup list, sizes and cipher
#   check      confirm WAL archiving reaches the repository
#   verify     re-read every file in the repository and check its checksum
#   full       take a full backup
#   diff       take a differential backup
#   incr       take an incremental backup
#   expire     apply the retention policy now
#   <other>    passed to pgbackrest as-is (e.g. stanza-create)
#
# Examples:
#   scripts/pgbr.sh homestead-pg info
#   scripts/pgbr.sh homestead-pg full
set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

container="$1"
command="$2"
shift 2

case "$command" in
    full | diff | incr) args=(--type="$command" backup) ;;
    *) args=("$command") ;;
esac

# Default to info-level console output unless the caller picks a level.
level=(--log-level-console=info)
case " $* " in *" --log-level-console="*) level=() ;; esac

# pgBackRest reads every PGBACKREST_* variable as an option. A container that
# still sets the image's old PGBACKREST_CRON_* names would make it warn, so
# those are dropped; PGBACKREST_CONFIG is a real option and is kept.
# shellcheck disable=SC2016 # expanded inside the container
exec docker exec -u postgres "$container" sh -c '
    for v in $(env | sed -n "s/^\(PGBACKREST_[A-Z_]*\)=.*/\1/p"); do
        [ "$v" = PGBACKREST_CONFIG ] || unset "$v"
    done
    exec pgbackrest --config="${PGBACKREST_CONFIG:-/etc/pgbackrest/pgbackrest.conf}" --stanza=default "$@"
' pgbr "${level[@]}" "${args[@]}" "$@"
