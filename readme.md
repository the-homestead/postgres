# Homestead PostgreSQL

PostgreSQL 18 with vector search, time-series, geospatial and full-text extensions, encrypted pgBackRest backups, and optional TLS. One Dockerfile, every extension switchable at build time, and named presets for common workloads.

```
ghcr.io/the-homestead/postgres:18
```

## Contents

- [Quick start](#quick-start)
- [Extensions](#extensions)
- [Configuration](#configuration)
- [Backups](#backups)
- [TLS](#tls)
- [Building](#building)
- [Helper scripts](#helper-scripts)
- [CI/CD](#cicd)
- [Repository layout](#repository-layout)
- [Upgrading from the OneDev image](#upgrading-from-the-onedev-image)

---

## Quick start

```bash
scripts/new-env.sh                 # writes .env with a fresh password and backup passphrase (mode 600)
docker run -d --name pg --env-file .env \
  -v pg_data:/var/lib/postgresql/18/docker \
  -v pg_backups:/pgbackrest/repo \
  -p 5432:5432 \
  ghcr.io/the-homestead/postgres:18
```

Or with Compose:

```yaml
services:
  postgres:
    image: ghcr.io/the-homestead/postgres:18
    restart: unless-stopped
    env_file: .env
    ports:
      - "5432:5432"
    volumes:
      - pg_data:/var/lib/postgresql/18/docker
      - pg_backups:/pgbackrest/repo
      - pg_spool:/pgbackrest/spool

volumes:
  pg_data:
  pg_backups:
  pg_spool:
```

> **Keep `PGBR_CIPHER_PASS` somewhere other than this server.** Backups are encrypted with it; without it they can't be restored.

---

## Extensions

| Extension | Version | Purpose |
|---|---|---|
| [pgvector](https://github.com/pgvector/pgvector) | 0.8.2 | Vector similarity search |
| [pgvectorscale](https://github.com/timescale/pgvectorscale) | 0.9.0 | DiskANN vector indexing |
| [TimescaleDB](https://github.com/timescale/timescaledb) | 2.x | Time-series tables and analytics |
| [PostGIS](https://postgis.net/) | 3.x | Geospatial types and queries |
| [PGroonga](https://pgroonga.github.io/) | latest | Full-text search for every language |
| [pg_cron](https://github.com/citusdata/pg_cron) | latest | Scheduled jobs inside the database |
| [pgmq](https://github.com/pgmq/pgmq) | 1.11.0 | Message queue in Postgres |
| [pg_later](https://github.com/ChuckHend/pg_later) | 0.4.0 | Asynchronous queries (needs pgmq) |
| [pgaudit](https://github.com/pgaudit/pgaudit) | 18.x | Statement audit logging |
| [pg_squeeze](https://github.com/cybertec-postgresql/pg_squeeze) | latest | Remove table bloat without long locks |
| [postgresql_anonymizer](https://gitlab.com/dalibo/postgresql_anonymizer) | 3.0.13 | Masking and anonymisation |
| [pg-safeupdate](https://github.com/eradman/pg-safeupdate) | latest | Blocks `UPDATE`/`DELETE` without `WHERE` |
| [pgBackRest](https://pgbackrest.org/) | 2.x | Backup, WAL archiving and restore |

[supercronic](https://github.com/aptible/supercronic) runs the backup schedule inside the container.

Notes:

- **TimescaleDB** must load first; the entrypoint orders `shared_preload_libraries` for you.
- **pg_later** needs pgmq installed in the same database. The entrypoint builds its `DATABASE_URL` from the `POSTGRES_*` variables unless you set one.
- **pg_squeeze** needs `wal_level = logical`, which the image sets.
- **anon** masking rules must be declared before use — see the [anon docs](https://postgresql-anonymizer.readthedocs.io/).
- **PostGIS** upgrades: after pulling an image with a newer PostGIS, run `docker exec <container> update-postgis.sh [db...]`. It updates `template_postgis`, `$POSTGRES_DB` and any databases you name.

### Tuning

Every extension works without tuning. The usual knobs, commented out in [`container/postgresql.conf`](container/postgresql.conf):

- **pgaudit**: `pgaudit.log`, `pgaudit.log_parameter`
- **pg_cron**: `cron.max_running_jobs`
- **pg_squeeze**: `squeeze.workers_per_database`, `squeeze.max_xlock_time`
- **Vector workloads**: `work_mem`, `maintenance_work_mem`
- **PostGIS / PGroonga**: `default_text_search_config`

Start conservative, measure under load, then raise one value at a time.

---

## Configuration

Every variable the image reads is listed, with defaults, in [`container/env.example`](container/env.example).

### Extension switches

Each `ENABLE_*` flag is a build argument and a runtime variable. At build time, `false` leaves the extension out of the image. At runtime, `false` keeps it out of `shared_preload_libraries`; the files stay in the image. Turning on at runtime something that was left out at build time doesn't work.

| Flag | Default | Controls |
|---|---|---|
| `ENABLE_PGVECTOR` | `true` | pgvector |
| `ENABLE_PGVECTORSCALE` | `true` | pgvectorscale |
| `ENABLE_PGLATER` | `true` | pg_later |
| `ENABLE_PGMQ` | `true` | pgmq |
| `ENABLE_ANON` | `true` | postgresql_anonymizer |
| `ENABLE_SAFEUPDATE` | `true` | pg-safeupdate |
| `ENABLE_TIMESCALEDB` | `true` | TimescaleDB |
| `ENABLE_POSTGIS` | `true` | PostGIS, topology, tiger geocoder |
| `ENABLE_PGCRON` | `true` | pg_cron |
| `ENABLE_PGAUDIT` | `true` | pgaudit |
| `ENABLE_PGSQUEEZE` | `true` | pg_squeeze |
| `ENABLE_PGROONGA` | `true` | PGroonga |
| `ENABLE_PGBACKREST` | `true` | pgBackRest, WAL archiving and the backup schedule |

### PostgreSQL

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_USER` | `postgres` | Superuser name |
| `POSTGRES_PASSWORD` | — | Superuser password (required) |
| `POSTGRES_DB` | `postgres` | Database created on first start |
| `PGCRON_DATABASE` | `postgres` | Database pg_cron reads its jobs from |

### What the entrypoint does

On every start, before handing off to the official `docker-entrypoint.sh`, [`container/entrypoint.sh`](container/entrypoint.sh):

1. builds `shared_preload_libraries` from the enabled extensions;
2. writes it, `archive_mode` and `archive_command` into the config used for new clusters **and** into an existing `postgresql.conf`, so a reused volume picks up changes;
3. writes `pgbackrest.conf` (mode 600) and the backup schedule, starts supercronic, and creates the `default` stanza once the server is up;
4. writes the TLS files and turns `ssl` on when they're supplied;
5. clears secrets from the environment so the server process never sees them.

Each setting is written once — restarting never piles up duplicate lines.

---

## Backups

Backups run with pgBackRest and are **always encrypted** (`aes-256-cbc`). Without `PGBR_CIPHER_PASS` the container stops with an error rather than write a backup anyone with disk access could read. `PGBR_ALLOW_UNENCRYPTED=true` turns that check off; it's for throwaway setups only.

WAL is archived continuously (`archive_timeout = 1800`), so a restore replays up to the last archived segment, not just to the last backup.

| Variable | Default | Description |
|---|---|---|
| `PGBR_CIPHER_PASS` | — | **Required.** Repository passphrase |
| `PGBR_ALLOW_UNENCRYPTED` | `false` | Allow backups without a passphrase |
| `PGBR_RETENTION_FULL` | `13` | Full backups to keep |
| `PGBR_CRON_FULL` | `5 2 * * 0` | Full backup schedule (Sunday 02:05) |
| `PGBR_CRON_INCR` | `5 2 * * 1-6` | Incremental schedule (Monday–Saturday 02:05) |
| `PGBR_MANAGE_CONFIG` | `1` | `0` to bring your own `pgbackrest.conf` |
| `PGBR_MANAGE_CRON` | `1` | `0` to bring your own cron file |
| `PGBR_CRON_FILE` | `/etc/cron.d/pgbackrest` | Cron file location |
| `PGBACKREST_CONFIG` | `/etc/pgbackrest/pgbackrest.conf` | pgBackRest config path |

> **Why `PGBR_*`?** pgBackRest treats every `PGBACKREST_*` environment variable as one of its own options and warns about names it doesn't know. The image's settings therefore use `PGBR_*`. The older `PGBACKREST_RETENTION_FULL`, `PGBACKREST_CRON_*` and `PGBACKREST_MANAGE_*` names are still read, then cleared.

The passphrase can't be changed on an existing repository. To rotate it, point the container at a new, empty repository volume and take a full backup.

### Object storage

Set `PGBR_S3_ENDPOINT` to keep the repository in S3-compatible storage instead of the local volume.

| Variable | Default | Description |
|---|---|---|
| `PGBR_S3_ENDPOINT` | — | Endpoint host, e.g. `s3.us-east-1.amazonaws.com` |
| `PGBR_S3_BUCKET` | — | Bucket (required with an endpoint) |
| `PGBR_S3_KEY` | — | Access key ID (required) |
| `PGBR_S3_KEY_SECRET` | — | Secret access key (required) |
| `PGBR_S3_REGION` | `us-east-1` | Region |
| `PGBR_S3_VERIFY_TLS` | `y` | `n` only for a self-signed endpoint |

### Day to day

```bash
scripts/pgbr.sh pg info            # backups, sizes, cipher
scripts/pgbr.sh pg check           # WAL archiving reaches the repository
scripts/pgbr.sh pg full            # full backup now
scripts/pgbr.sh pg verify          # re-read and checksum every file in the repository
scripts/restore-check.sh pg        # restore the latest backup into a throwaway container
```

Run `restore-check.sh` once backups are set up and regularly after that: a backup that has never been restored hasn't been tested. It can also run a query against the restored copy, to compare with production:

```bash
scripts/restore-check.sh pg -- "\c mydb
SELECT count(*) FROM orders"
```

---

## TLS

TLS turns on when `SERVER_CRT` and `SERVER_KEY` are both set. The entrypoint writes them to `/var/lib/postgresql/` with mode 600 and sets `ssl`, `ssl_cert_file` and `ssl_key_file`. `ROOT_CA_CRT` adds `ssl_ca_file` for client-certificate checks. Setting only one of the certificate and key is an error. Without either, the server starts without TLS.

| Variable | Description |
|---|---|
| `SERVER_CRT` | Server certificate (PEM) |
| `SERVER_KEY` | Server private key (PEM) |
| `ROOT_CA_CRT` | CA certificate (PEM), optional |

[`keys/generate-certs.sh`](keys/generate-certs.sh) creates a local CA plus server and client certificates and prints the three variables ready to paste. See [`keys/README.md`](keys/README.md). Nothing under `keys/` except the script and its README is tracked by git.

---

## Building

The build uses [`docker buildx bake`](https://docs.docker.com/build/bake/). Extension stages build in parallel, and the Rust extensions cross-compile for arm64 instead of running under emulation.

| Target | Platforms | Contents |
|---|---|---|
| `full` | amd64, arm64 | Every extension |
| `minimal` | amd64, arm64 | pgaudit, pg_cron, safeupdate, pgBackRest |
| `vector` | amd64, arm64 | pgvector, pgvectorscale, pgmq, pg_later, pg_squeeze |
| `analytics` | amd64, arm64 | TimescaleDB, PostGIS, pgvector, pg_squeeze |
| `dev` | amd64 | Quick local build without the slowest Rust extensions |
| `ci` | amd64 | Smallest build, no backups |
| `all` | — | `full`, `minimal`, `vector`, `analytics` |

```bash
scripts/build.sh                   # dev, loaded into the local daemon
scripts/build.sh full              # full, for this machine's architecture, loaded
scripts/build.sh full --push       # full, every platform, pushed
TAG=18-rc scripts/build.sh all --push
```

Tags come from `REGISTRY` (`ghcr.io/the-homestead`), `REPOSITORY` (`postgres`) and `TAG` (`18`):

| Tag | Meaning |
|---|---|
| `18`, `18-full` | `full` preset |
| `18-minimal`, `18-vector`, `18-analytics` | Other presets |
| `pg18-<target>` | Pinned to the PostgreSQL major version |
| `dev`, `ci-18` | Local and CI builds |

Pushing needs `docker login ghcr.io` with a token that has `write:packages`.

For arm64 builds of the C extensions on an x86 machine, register QEMU once:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

---

## Helper scripts

| Script | What it does |
|---|---|
| [`scripts/new-env.sh`](scripts/new-env.sh) | Writes `.env` from `env.example` with a generated password and backup passphrase (mode 600; never overwrites) |
| [`scripts/build.sh`](scripts/build.sh) | Builds a bake target, loading it locally or pushing it |
| [`scripts/pgbr.sh`](scripts/pgbr.sh) | Runs pgBackRest in a running container: `info`, `check`, `verify`, `full`, `diff`, `incr`, `expire` |
| [`scripts/restore-check.sh`](scripts/restore-check.sh) | Restores a backup into a throwaway, network-less container, replays WAL, lists databases, optionally runs a query |
| [`scripts/smoke-test.sh`](scripts/smoke-test.sh) | Starts an image four ways and checks each one; CI runs it on every build |
| [`keys/generate-certs.sh`](keys/generate-certs.sh) | Creates a local CA plus server and client certificates |

`smoke-test.sh` takes an optional entrypoint path, so a script change can be tested against an existing image without a rebuild:

```bash
scripts/smoke-test.sh ghcr.io/the-homestead/postgres:18 container/entrypoint.sh
```

It checks:

1. backups on without a passphrase → refuses to start;
2. backups and TLS on → `ssl` and `archive_mode` on, encrypted full backup, `verify` passes, repository files are ciphertext, no pgBackRest warnings;
3. a restart of (2) → each managed setting appears once in `postgresql.conf`;
4. backups and TLS off → plain start.

---

## CI/CD

GitHub Actions in [`.github/workflows`](.github/workflows):

| Workflow | Trigger | Does |
|---|---|---|
| `lint.yml` | push, pull request | shellcheck on every script, hadolint on the Dockerfile, checks the bake file parses |
| `build.yml` | pull request | builds `full` for amd64 and runs the smoke test; pushes nothing |
| `build.yml` | push to `master` | builds and smoke-tests, then builds every platform and pushes `ghcr.io/the-homestead/postgres:18` |
| `build.yml` | tag `v*` | as above, tagged with the version (`v18.3.1` → `18.3.1`) |
| `build.yml` | manual | builds and pushes a chosen target |

Publishing uses the workflow's own `GITHUB_TOKEN`; no secrets need configuring. The first push creates the package as private under the organisation; change its visibility in the package settings if needed. Dependabot keeps the actions and the base image current.

---

## Repository layout

```
container/
  Dockerfile                  multi-stage build, extensions behind ENABLE_* flags
  docker-bake.hcl             presets, platforms, tags
  entrypoint.sh               runtime configuration (see "What the entrypoint does")
  initdb-pgbackrest.sh        creates the stanza on first start
  initdb-postgis.sh           template_postgis and PostGIS extensions on first start
  initdb-extensions.sh        pgmq, pg_later, pg_cron on first start
  update-postgis.sh           PostGIS upgrade helper, installed in the image
  postgresql.conf.sample      baseline for new clusters
  postgresql.conf             example for mounting with -c config_file=
  pgbackrest.conf.example     what the entrypoint writes, for bring-your-own setups
  pgbackrest.cron.example     the default schedule
  env.example                 every runtime variable
scripts/                      helper scripts (above); scripts/lib/ holds their internals
keys/                         TLS material (only the script and README are tracked)
.github/                      workflows and Dependabot
```

---

## Upgrading from the OneDev image

The image used to be published as `git.myhm.space/homestead/postgres/pg18:<tag>`. That registry is gone.

1. Change the image to `ghcr.io/the-homestead/postgres:18`.
2. Add `PGBR_CIPHER_PASS` (keep a copy off the server) if `ENABLE_PGBACKREST` is `true`.
3. Optionally rename `PGBACKREST_RETENTION_FULL` / `PGBACKREST_CRON_FULL` / `PGBACKREST_CRON_INCR` to `PGBR_*`. The old names still work.
4. Recreate the container, then run `scripts/pgbr.sh <container> info` and `scripts/restore-check.sh <container>`.

An existing data volume is reused as-is; the entrypoint updates its `postgresql.conf` in place. A repository created before encryption was turned on can't be encrypted afterwards: give the encrypted setup a new, empty repository volume.
