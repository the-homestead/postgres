# Custom PostgreSQL Image

A hardened, fully configurable PostgreSQL 18 image with vector search, geospatial, full-text search, scheduled backups, and safe update protection built in. Every extension can be toggled on or off at build time via `ARG` flags — giving you a single Dockerfile with named presets for different workloads.

## Included Extensions

| Extension | Version | Purpose |
|---|---|---|
| [pgvector](https://github.com/pgvector/pgvector) | 0.8.2 | Vector similarity search |
| [pgvectorscale](https://github.com/timescale/pgvectorscale) | 0.9.0 | High-performance vector indexing (DiskANN) |
| [TimescaleDB](https://github.com/timescale/timescaledb) | 2.25.1 | Time-series data management and analytics |
| [PostGIS](https://postgis.net/) | 3.x | Geospatial data types and queries |
| [PGroonga](https://pgroonga.github.io/) | latest | Full-text search for all languages |
| [pg_cron](https://github.com/citusdata/pg_cron) | latest | In-database job scheduling |
| [pgmq](https://github.com/pgmq/pgmq) | 1.11.0 | Lightweight message queue inside Postgres |
| [pg_later](https://github.com/ChuckHend/pg_later) | 0.4.0 | Async query execution (requires pgmq) |
| [pgaudit](https://github.com/pgaudit/pgaudit) | 18.0 | Full audit logging of SQL statements |
| [pg_squeeze](https://github.com/cybertec-postgresql/pg_squeeze) | latest | Online table/index bloat reclamation without locking |
| [postgresql_anonymizer](https://gitlab.com/dalibo/postgresql_anonymizer) | 3.0.13 | Data masking and anonymization |
| [pg-safeupdate](https://github.com/eradman/pg-safeupdate) | latest | Prevents `UPDATE`/`DELETE` without a `WHERE` clause |
| [pgBackRest](https://pgbackrest.org/) | latest | Backup and restore |

## Additional Tools

- **[supercronic](https://github.com/aptible/supercronic)** `v0.2.43` — Cron scheduler for containerized environments, used to run scheduled pgBackRest backups.

---

## Configurable Extensions

Every extension is controlled by a build-time `ARG` (and a matching runtime `ENV`). Set any to `false` to exclude it entirely from the image — the library files won't be copied, the apt packages won't be installed, and `shared_preload_libraries` is built dynamically at container start from whatever remains enabled.

| Build ARG | Default | Controls |
|---|---|---|
| `ENABLE_PGVECTOR` | `true` | pgvector |
| `ENABLE_PGVECTORSCALE` | `true` | pgvectorscale |
| `ENABLE_PGLATER` | `true` | pg_later |
| `ENABLE_PGMQ` | `true` | pgmq |
| `ENABLE_ANON` | `true` | postgresql_anonymizer |
| `ENABLE_SAFEUPDATE` | `true` | pg-safeupdate |
| `ENABLE_TIMESCALEDB` | `true` | TimescaleDB |
| `ENABLE_POSTGIS` | `true` | PostGIS + topology + tiger geocoder |
| `ENABLE_PGCRON` | `true` | pg_cron |
| `ENABLE_PGAUDIT` | `true` | pgaudit |
| `ENABLE_PGSQUEEZE` | `true` | pg_squeeze |
| `ENABLE_PGROONGA` | `true` | PGroonga |
| `ENABLE_PGBACKREST` | `true` | pgBackRest + supercronic scheduler |

> **Build-time vs runtime:** Disabling an extension at runtime (`-e ENABLE_X=false`) suppresses it from `shared_preload_libraries` but the files still exist in the image. To actually reduce image size you must disable at **build time** via `--build-arg` or a bake target.

---

## Backup Schedule (pgBackRest)

Backups are managed automatically via supercronic. The default schedule:

| Type | Schedule | Default Cron |
|---|---|---|
| Full | Every Sunday | `5 2 * * 0` |
| Incremental | Mon–Sat | `5 2 * * 1-6` |

Full backups are retained for **13 weeks** by default.

---

## Extension Notes

- **pg_later** depends on **pgmq** being installed in the database first.
- **pg_squeeze** requires `wal_level = logical` — set by default in this image.
- **anon** enforces masking policies at the session level via startup hooks. Masking rules must be declared before use — see the [anon docs](https://postgresql-anonymizer.readthedocs.io/).
- **TimescaleDB** must be the **first** entry in `shared_preload_libraries` — the entrypoint handles this automatically regardless of which other extensions are enabled.

---

## Environment Variables

### PostgreSQL

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_USER` | `postgres` | Superuser username |
| `POSTGRES_PASSWORD` | — | Superuser password (required) |
| `POSTGRES_DB` | `postgres` | Default database name |

### pgBackRest

| Variable | Default | Description |
|---|---|---|
| `PGBACKREST_CONFIG` | `/etc/pgbackrest/pgbackrest.conf` | Path to pgBackRest config file |
| `PGBACKREST_RETENTION_FULL` | `13` | Number of full backups to retain |
| `PGBACKREST_CRON_FULL` | `5 2 * * 0` | Cron expression for full backups |
| `PGBACKREST_CRON_INCR` | `5 2 * * 1-6` | Cron expression for incremental backups |
| `PGBACKREST_MANAGE_CONFIG` | `1` | Set to `0` to skip auto-generating pgbackrest.conf |
| `PGBACKREST_MANAGE_CRON` | `1` | Set to `0` to skip auto-generating the cron file |

### S3 Backup (optional)

When `PGBR_S3_ENDPOINT` is set, pgBackRest switches from local disk to S3 mode. All four variables below are required together.

| Variable | Default | Description |
|---|---|---|
| `PGBR_S3_ENDPOINT` | — | S3-compatible endpoint URL |
| `PGBR_S3_BUCKET` | — | Bucket name |
| `PGBR_S3_KEY` | — | Access key ID |
| `PGBR_S3_KEY_SECRET` | — | Secret access key |
| `PGBR_S3_REGION` | `us-east-1` | S3 region |

---

## Registry

Images are published to the Homestead OneDev package registry.

```
git.myhm.space/homestead/postgres:<tag>
```

### Login

```bash
docker login git.myhm.space
```

Your account must have **package write** permission over the project to push images.

---

## Building

This project uses [`docker buildx bake`](https://docs.docker.com/build/bake/) with a `docker-bake.hcl` file that defines named presets. BuildKit runs all extension build stages in parallel and uses `--mount=type=cache` for Cargo and apt so incremental rebuilds are fast.

### Named presets

| Target | Description |
|---|---|
| `full` | Every extension enabled. Multi-platform (amd64 + arm64). |
| `minimal` | Auditing, safe-updates, cron, and backups only. |
| `vector` | AI/RAG workloads: pgvector, pgvectorscale, pgmq, pg_later. |
| `analytics` | Time-series + geospatial: TimescaleDB, PostGIS, pgvector. |
| `dev` | Fast local build — single platform, skips slowest Rust extensions. |
| `ci` | Minimal single-platform build for CI pipelines, no backups. |

### Quick start — local test

```bash
# Create a BuildKit builder (one-time setup)
docker buildx create --name homestead --driver docker-container --use

# Build the dev preset and load it into your local Docker daemon
docker buildx bake dev --load
```

### Push to registry

```bash
# Push a single preset
docker buildx bake dev --push

# Push all production variants in parallel (full, minimal, vector, analytics)
docker buildx bake all --push
```

> `--push` and `--load` are mutually exclusive. `--load` is single-platform only (local testing). `--push` supports multi-platform and sends directly to the registry.

### Build with specific extensions disabled

```bash
docker buildx build \
  --build-arg ENABLE_PGVECTORSCALE=false \
  --build-arg ENABLE_ANON=false \
  --build-arg ENABLE_PGROONGA=false \
  --load -t git.myhm.space/homestead/postgres:custom .
```

### Override the registry or tag

```bash
REGISTRY=git.myhm.space/homestead/postgres TAG=18-rc docker buildx bake full --push
```

### Per-architecture tags (manual multi-arch)

If you prefer explicit per-arch tags over the bake manifest approach:

```bash
# amd64
docker buildx build --platform linux/amd64 --push \
  -t git.myhm.space/homestead/postgres:18-amd64 \
  -f container/Dockerfile container

# arm64
docker buildx build --platform linux/arm64 --push \
  -t git.myhm.space/homestead/postgres:18-arm64 \
  -f container/Dockerfile container

# Combine into a multi-arch manifest
docker buildx imagetools create \
  --tag git.myhm.space/homestead/postgres:18 \
  --tag git.myhm.space/homestead/postgres:latest \
  git.myhm.space/homestead/postgres:18-amd64 \
  git.myhm.space/homestead/postgres:18-arm64
```

> For arm64 builds on x86 hardware, install QEMU first:
> ```bash
> docker run --privileged --rm tonistiigi/binfmt --install all
> ```

### Tag convention

| Tag | Description |
|---|---|
| `latest` / `latest-full` | All extensions, multi-arch |
| `latest-minimal` | Minimal build, multi-arch |
| `latest-vector` | Vector/AI build, multi-arch |
| `latest-analytics` | Time-series + geo build, multi-arch |
| `dev` | Local dev build, amd64 only |
| `pg18-full` | Postgres-version-pinned alias for full |

---

## Testing

```bash
# Spin up a container from the dev build
docker run --rm -d \
  --name pg-test \
  -e POSTGRES_PASSWORD=testpass \
  -e POSTGRES_DB=testdb \
  -p 5432:5432 \
  git.myhm.space/homestead/postgres:dev

# Watch startup logs (extension loading, stanza creation, etc.)
docker logs -f pg-test

# Verify which extensions loaded
docker exec -it pg-test psql -U postgres -d testdb -c "
  SELECT name, default_version, installed_version
  FROM pg_available_extensions
  WHERE installed_version IS NOT NULL
  ORDER BY name;
"

# Check shared_preload_libraries was built correctly
docker exec -it pg-test psql -U postgres -c "SHOW shared_preload_libraries;"

# Verify pgBackRest stanza
docker exec -it pg-test su - postgres -c "pgbackrest --stanza=default info"
```

### Compose test stacks

Two test setups are available under `test/`:

- `test/basic/docker-compose.test.yml` — minimal quick-start with defaults.
- `test/with-config/docker-compose.test.yml` — production-style stack with mounted config files.

```bash
# Basic
docker compose -f test/basic/docker-compose.test.yml up -d

# With config files mounted
docker compose -f test/with-config/docker-compose.test.yml up -d
```

**Basic connection:**
- Host: `127.0.0.1` · Port: `5432` · User: `postgres` · Password: `testpassword` · Database: `testdb`

**With-config connection:**
- Host: `127.0.0.1` · Port: `55432` · User: `postgres` · Password: `testpassword` · Database: `testdb`

---

## CI/CD

Add a **Build Docker Image** step to your OneDev job and configure the built-in registry login using an access token secret with package write permissions. Set the image name to the appropriate bake target tag, then run `docker buildx bake` as a script step.

---

## Scripts

| File | Description |
|---|---|
| `container/entrypoint.sh` | Dynamically builds `shared_preload_libraries` from `ENABLE_*` vars, writes pgBackRest config, starts supercronic, then hands off to the standard Postgres entrypoint |
| `container/initdb-pgbackrest.sh` | Runs once on first start to create the pgBackRest `default` stanza (skipped if `ENABLE_PGBACKREST=false`) |
| `container/initdb-postgis.sh` | Runs once on first start to create `template_postgis` and load PostGIS extensions (skipped if `ENABLE_POSTGIS=false`) |
| `container/update-postgis.sh` | Run manually to upgrade PostGIS extensions in existing databases (skipped if `ENABLE_POSTGIS=false`) |

## Config Files

| File | Description |
|---|---|
| `container/configs/postgresql.conf.sample` | Official PostgreSQL 18 sample baseline (tracked in repo) |
| `container/configs/postgresql.conf` | Runtime Postgres config example for `config_file=` mounting |
| `container/configs/pgbackrest.conf.example` | pgBackRest config example for local/S3 modes |
| `container/configs/pgbackrest.cron.example` | Example cron entries used for scheduled backups |

---

## Optional Extension Tuning

Most extensions work out-of-the-box. Common optional knobs (kept commented in config by default):

- **pgaudit**: `pgaudit.log`, `pgaudit.log_parameter`
- **pg_cron**: `cron.max_running_jobs`
- **pg_squeeze**: `squeeze.workers_per_database`, `squeeze.max_xlock_time`
- **Vector workloads**: `work_mem`, `maintenance_work_mem`
- **PostGIS / PGroonga**: `default_text_search_config`

Use conservative values first, validate under load, then tune incrementally.

---

## Updating PostGIS

After pulling a new image with an updated PostGIS version, run the update script against your running container:

```bash
docker exec -it <container> update-postgis.sh
```

To update additional databases beyond `template_postgis` and `$POSTGRES_DB`, pass them as arguments:

```bash
docker exec -it <container> update-postgis.sh mydb otherdb
```

#  TLS?

https://sliplane.io/blog/setup-tls-for-postgresql-in-docker