#!/usr/bin/env bash
# restore-check.sh — prove the latest backup restores.
#
# Restores the newest backup from a running container's repository into a
# throwaway container (no network, repository mounted read-only), replays the
# archived WAL, starts PostgreSQL and lists the databases. The source container
# is only read from.
#
# Usage:
#   scripts/restore-check.sh <container> [backup-label] [-- <sql>]
#
# With `-- <sql>` the query runs against the restored cluster after start-up
# and its output is printed (e.g. a row count to compare with production).
#
# Examples:
#   scripts/restore-check.sh homestead-pg
#   scripts/restore-check.sh homestead-pg 20261109-202543F
#   scripts/restore-check.sh homestead-pg -- "SELECT count(*) FROM my_table"
set -euo pipefail

if [ $# -lt 1 ]; then
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

source_container="$1"
shift
backup_set=""
check_sql=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then
    backup_set="$1"
    shift
fi
if [ $# -gt 0 ] && [ "$1" = "--" ]; then
    shift
    check_sql="${1:-}"
fi

check_container="restore-check-$$"
image="$(docker inspect --format '{{.Config.Image}}' "$source_container")"
repo="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/pgbackrest/repo"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}' "$source_container")"
if [ -z "$repo" ]; then
    echo "ERROR: ${source_container} has no volume or bind mount at /pgbackrest/repo." >&2
    exit 1
fi

# The config holds the cipher passphrase: it stays mode 600 in a private dir.
workdir="$(mktemp -d)"
cleanup() {
    docker rm -f "$check_container" >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

config_path="$(docker exec "$source_container" sh -c 'echo "${PGBACKREST_CONFIG:-/etc/pgbackrest/pgbackrest.conf}"')"
docker exec "$source_container" cat "$config_path" >"$workdir/pgbackrest.conf"
chmod 600 "$workdir/pgbackrest.conf"
cp "$(dirname "$0")/lib/restore-in-container.sh" "$workdir/restore.sh"
chmod 644 "$workdir/restore.sh"
# Container root reads both files, then copies the config for postgres.
chmod 711 "$workdir"
db_user="$(docker exec "$source_container" sh -c 'echo "${POSTGRES_USER:-postgres}"')"

echo ">>> Restoring ${backup_set:-the latest backup} from ${repo} with ${image}"

docker run --rm --name "$check_container" --network none \
    -v "${repo}:/pgbackrest/repo:ro" \
    -v "${workdir}/pgbackrest.conf:/run/restore/pgbackrest.conf:ro" \
    -v "${workdir}/restore.sh:/run/restore/restore.sh:ro" \
    -e BACKUP_SET="$backup_set" \
    -e DB_USER="$db_user" \
    -e CHECK_SQL="$check_sql" \
    --entrypoint bash "$image" /run/restore/restore.sh

echo ">>> RESTORE CHECK PASSED"
