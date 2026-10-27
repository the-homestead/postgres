# syntax=docker/dockerfile:1
# ^^^ Enables the latest BuildKit frontend — required for cache mounts, bind mounts from other stages, etc.

##############################################################################
# GLOBAL BUILD ARGUMENTS
# Override any of these with:  --build-arg KEY=value  or via docker-bake.hcl
##############################################################################

# ── Postgres / base ──────────────────────────────────────────────────────────
ARG POSTGRESQL_VERSION=18
ARG DEBIAN_CODENAME=bookworm

# ── Extension versions ───────────────────────────────────────────────────────
ARG PGVECTOR_VERSION=0.8.2
ARG PGVECTORSCALE_VERSION=0.9.0
ARG PGLATER_VERSION=0.4.0
ARG PGMQ_VERSION=v1.11.0
ARG ANON_VERSION=3.0.13
ARG TIMESCALEDB_VERSION=2.25.1
ARG SUPERCRONIC_VERSION=v0.2.43
ARG POSTGIS_MAJOR=3
ARG SAFEUPDATE_URL=https://github.com/eradman/pg-safeupdate/archive/master.tar.gz

# ── Feature flags (build-time; also exposed as ENV for runtime scripts) ──────
# Set any to "false" to exclude that extension entirely from the image.
ARG ENABLE_PGVECTOR=true
ARG ENABLE_PGVECTORSCALE=true
ARG ENABLE_PGLATER=true
ARG ENABLE_PGMQ=true
ARG ENABLE_ANON=true
ARG ENABLE_SAFEUPDATE=true
ARG ENABLE_TIMESCALEDB=true
ARG ENABLE_POSTGIS=true
ARG ENABLE_PGCRON=true
ARG ENABLE_PGAUDIT=true
ARG ENABLE_PGSQUEEZE=true
ARG ENABLE_PGROONGA=true
ARG ENABLE_PGBACKREST=true


##############################################################################
# BASE BUILDER — always runs on the native BUILD platform (never emulated).
# Cross-compilation handles arm64 targets instead of QEMU emulation,
# cutting Rust build times from ~45 min to ~5 min per extension.
##############################################################################
FROM --platform=$BUILDPLATFORM postgres:${POSTGRESQL_VERSION}-${DEBIAN_CODENAME} AS base-builder

ARG POSTGRESQL_VERSION
# TARGETARCH is injected by BuildKit: "amd64" or "arm64"
ARG TARGETARCH

RUN --mount=type=cache,id=apt-builder,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-builder-lib,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        clang cmake curl g++ gcc git \
        libclang-dev libpq-dev \
        postgresql-${POSTGRESQL_VERSION} \
        postgresql-server-dev-${POSTGRESQL_VERSION} \
        make zlib1g zlib1g-dev pkg-config \
        libssl-dev ca-certificates jq wget \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu

# Install Rust with both native and cross-compile targets.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    ~/.cargo/bin/rustup component add rustfmt && \
    ~/.cargo/bin/rustup target add aarch64-unknown-linux-gnu

# Wire up the cross-linker so cargo uses it when targeting arm64.
RUN mkdir -p ~/.cargo && printf '[target.aarch64-unknown-linux-gnu]\nlinker = "aarch64-linux-gnu-gcc"\n' >> ~/.cargo/config.toml

# Helper: emit the Rust target triple for the requested TARGETARCH.
# Used by every Rust extension stage below.
ENV CROSS_TARGET_amd64=x86_64-unknown-linux-gnu
ENV CROSS_TARGET_arm64=aarch64-unknown-linux-gnu


##############################################################################
# PER-EXTENSION BUILD STAGES  (run in parallel by BuildKit)
# Each stage guards its work behind the matching ENABLE_* flag.
# When disabled we still create the expected directory so bind-mounts below
# always succeed.
##############################################################################

# ── pgvectorscale ─────────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM base-builder AS build-pgvectorscale
ARG POSTGRESQL_VERSION PGVECTORSCALE_VERSION ENABLE_PGVECTORSCALE TARGETARCH

RUN --mount=type=cache,id=cargo-registry,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/root/.cargo/git,sharing=locked \
    if [ "${ENABLE_PGVECTORSCALE}" = "true" ]; then \
        RUST_TARGET=$(eval echo \${CROSS_TARGET_${TARGETARCH:-amd64}}) && \
        cd /tmp && git clone --depth 1 --branch "${PGVECTORSCALE_VERSION}" \
            https://github.com/timescale/pgvectorscale && \
        cd pgvectorscale && \
        PGRX_VER=$(~/.cargo/bin/cargo metadata --format-version 1 \
            | jq -r '.packages[] | select(.name == "pgrx") | .version') && \
        ~/.cargo/bin/cargo install --locked cargo-pgrx --version "${PGRX_VER}" && \
        ~/.cargo/bin/cargo pgrx init --pg${POSTGRESQL_VERSION} pg_config && \
        cd pgvectorscale && \
        ~/.cargo/bin/cargo pgrx package --target "${RUST_TARGET}"; \
    else \
        mkdir -p /tmp/pgvectorscale; \
    fi


# ── pg_later ──────────────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM base-builder AS build-pglater
ARG POSTGRESQL_VERSION PGLATER_VERSION ENABLE_PGLATER TARGETARCH

RUN --mount=type=cache,id=cargo-registry,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/root/.cargo/git,sharing=locked \
    if [ "${ENABLE_PGLATER}" = "true" ]; then \
        RUST_TARGET=$(eval echo \${CROSS_TARGET_${TARGETARCH:-amd64}}) && \
        cd /tmp && git clone --depth 1 --branch "v${PGLATER_VERSION}" \
            https://github.com/ChuckHend/pg_later && \
        cd pg_later && \
        PGRX_VER=$(~/.cargo/bin/cargo metadata --format-version 1 \
            | jq -r '.packages[] | select(.name == "pgrx") | .version') && \
        ~/.cargo/bin/cargo install --locked cargo-pgrx --version "${PGRX_VER}" && \
        ~/.cargo/bin/cargo pgrx init --pg${POSTGRESQL_VERSION} pg_config && \
        ~/.cargo/bin/cargo pgrx package --target "${RUST_TARGET}"; \
    else \
        mkdir -p /tmp/pg_later; \
    fi


# ── postgresql_anonymizer (anon) ──────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM base-builder AS build-anon
ARG POSTGRESQL_VERSION ANON_VERSION ENABLE_ANON TARGETARCH

RUN --mount=type=cache,id=cargo-registry,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,id=cargo-git,target=/root/.cargo/git,sharing=locked \
    if [ "${ENABLE_ANON}" = "true" ]; then \
        RUST_TARGET=$(eval echo \${CROSS_TARGET_${TARGETARCH:-amd64}}) && \
        cd /tmp && git clone --depth 1 --branch "${ANON_VERSION}" \
            https://gitlab.com/dalibo/postgresql_anonymizer && \
        cd postgresql_anonymizer && \
        PGRX_VER=$(~/.cargo/bin/cargo metadata --format-version 1 \
            | jq -r '.packages[] | select(.name == "pgrx") | .version') && \
        ~/.cargo/bin/cargo install --locked cargo-pgrx --version "${PGRX_VER}" && \
        ~/.cargo/bin/cargo pgrx init --pg${POSTGRESQL_VERSION} pg_config && \
        ~/.cargo/bin/cargo pgrx package --target "${RUST_TARGET}"; \
    else \
        mkdir -p /tmp/postgresql_anonymizer; \
    fi


# ── pgvector (C, no Rust) ─────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM base-builder AS build-pgvector
ARG PGVECTOR_VERSION ENABLE_PGVECTOR

RUN if [ "${ENABLE_PGVECTOR}" = "true" ]; then \
        cd /tmp && git clone --depth 1 --branch "v${PGVECTOR_VERSION}" \
            https://github.com/pgvector/pgvector && \
        cd pgvector && make; \
    else \
        mkdir -p /tmp/pgvector; \
    fi


# ── pgmq (pure SQL — no compilation) ─────────────────────────────────────────
FROM --platform=$BUILDPLATFORM base-builder AS build-pgmq
ARG PGMQ_VERSION ENABLE_PGMQ

RUN if [ "${ENABLE_PGMQ}" = "true" ]; then \
        cd /tmp && git clone --depth 1 --branch "${PGMQ_VERSION}" \
            https://github.com/pgmq/pgmq && \
        cd pgmq/pgmq-extension && \
        VER=$(grep "^default_version" pgmq.control | sed -r "s/default_version[^']+'([^']+).*/\1/") && \
        cp sql/pgmq.sql "sql/pgmq--${VER}.sql"; \
    else \
        mkdir -p /tmp/pgmq/pgmq-extension/sql; \
        touch /tmp/pgmq/pgmq-extension/pgmq.control; \
    fi


# ── pg-safeupdate (C) ─────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM base-builder AS build-safeupdate
ARG SAFEUPDATE_URL ENABLE_SAFEUPDATE

RUN if [ "${ENABLE_SAFEUPDATE}" = "true" ]; then \
        cd /tmp && wget -q -O - "${SAFEUPDATE_URL}" | tar xzf - && \
        cd pg-safeupdate-master && gmake; \
    else \
        mkdir -p /tmp/pg-safeupdate-master; \
    fi


##############################################################################
# FINAL IMAGE
##############################################################################
FROM postgres:${POSTGRESQL_VERSION}-${DEBIAN_CODENAME}

# Re-declare all ARGs after FROM so they are in scope for this stage.
ARG POSTGRESQL_VERSION DEBIAN_CODENAME POSTGIS_MAJOR SUPERCRONIC_VERSION
ARG PGVECTORSCALE_VERSION PGLATER_VERSION
ARG ENABLE_PGVECTOR ENABLE_PGVECTORSCALE ENABLE_PGLATER ENABLE_PGMQ
ARG ENABLE_ANON ENABLE_SAFEUPDATE ENABLE_TIMESCALEDB ENABLE_POSTGIS
ARG ENABLE_PGCRON ENABLE_PGAUDIT ENABLE_PGSQUEEZE ENABLE_PGROONGA ENABLE_PGBACKREST

# Bake the build-time flags into ENV so runtime scripts (entrypoint, initdb,
# update-postgis) can read them without being re-passed by the user.
ENV ENABLE_PGVECTOR=${ENABLE_PGVECTOR:-true} \
    ENABLE_PGVECTORSCALE=${ENABLE_PGVECTORSCALE:-true} \
    ENABLE_PGLATER=${ENABLE_PGLATER:-true} \
    ENABLE_PGMQ=${ENABLE_PGMQ:-true} \
    ENABLE_ANON=${ENABLE_ANON:-true} \
    ENABLE_SAFEUPDATE=${ENABLE_SAFEUPDATE:-true} \
    ENABLE_TIMESCALEDB=${ENABLE_TIMESCALEDB:-true} \
    ENABLE_POSTGIS=${ENABLE_POSTGIS:-true} \
    ENABLE_PGCRON=${ENABLE_PGCRON:-true} \
    ENABLE_PGAUDIT=${ENABLE_PGAUDIT:-true} \
    ENABLE_PGSQUEEZE=${ENABLE_PGSQUEEZE:-true} \
    ENABLE_PGROONGA=${ENABLE_PGROONGA:-true} \
    ENABLE_PGBACKREST=${ENABLE_PGBACKREST:-true}

# ── STEP 1: System dependencies (conditional by feature flag) ────────────────
RUN --mount=type=cache,id=apt-final,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-final-lib,target=/var/lib/apt,sharing=locked \
    set -ex && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        lsb-release wget ca-certificates curl tzdata libxml2 && \
    CODENAME=$(lsb_release --codename --short) && \
    # ── Groonga / Arrow repos (PGroonga) ──
    if [ "${ENABLE_PGROONGA}" = "true" ]; then \
        wget -q "https://apache.jfrog.io/artifactory/arrow/debian/apache-arrow-apt-source-latest-${CODENAME}.deb" && \
        apt-get install -y -V ./apache-arrow-apt-source-latest-*.deb && rm -f ./*.deb && \
        wget -q "https://packages.groonga.org/debian/groonga-apt-source-latest-${CODENAME}.deb" && \
        apt-get install -y -V ./groonga-apt-source-latest-*.deb && rm -f ./*.deb; \
    fi && \
    # ── TimescaleDB repo ──
    if [ "${ENABLE_TIMESCALEDB}" = "true" ]; then \
        wget -q -O - https://packagecloud.io/timescale/timescaledb/gpgkey \
            | gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg && \
        echo "deb https://packagecloud.io/timescale/timescaledb/debian/ ${CODENAME} main" \
            > /etc/apt/sources.list.d/timescaledb.list; \
    fi && \
    apt-get update && \
    # ── Build a dynamic package list ──
    PKGS="" && \
    [ "${ENABLE_PGBACKREST}"  = "true" ] && PKGS="${PKGS} pgbackrest libssh2-1"                                                                                     || true && \
    [ "${ENABLE_TIMESCALEDB}" = "true" ] && PKGS="${PKGS} timescaledb-2-postgresql-${POSTGRESQL_VERSION}"                                                           || true && \
    [ "${ENABLE_POSTGIS}"     = "true" ] && PKGS="${PKGS} postgresql-${POSTGRESQL_VERSION}-postgis-${POSTGIS_MAJOR} postgresql-${POSTGRESQL_VERSION}-postgis-${POSTGIS_MAJOR}-scripts" || true && \
    [ "${ENABLE_PGCRON}"      = "true" ] && PKGS="${PKGS} postgresql-${POSTGRESQL_VERSION}-cron"                                                                    || true && \
    [ "${ENABLE_PGAUDIT}"     = "true" ] && PKGS="${PKGS} postgresql-${POSTGRESQL_VERSION}-pgaudit"                                                                 || true && \
    [ "${ENABLE_PGSQUEEZE}"   = "true" ] && PKGS="${PKGS} postgresql-${POSTGRESQL_VERSION}-squeeze"                                                                 || true && \
    [ "${ENABLE_PGROONGA}"    = "true" ] && PKGS="${PKGS} postgresql-${POSTGRESQL_VERSION}-pgdg-pgroonga groonga-normalizer-mysql groonga-token-filter-stem groonga-tokenizer-mecab" || true && \
    [ -n "${PKGS}" ] && apt-get install -y --no-install-recommends ${PKGS} || true && \
    # ── Convenience symlinks ──
    for BIN in postgres initdb pg_ctl psql pg_isready; do \
        ln -sf "/usr/lib/postgresql/${POSTGRESQL_VERSION}/bin/${BIN}" "/usr/local/bin/${BIN}"; \
    done && \
    apt-get clean

# ── STEP 2: Copy pre-built extensions (conditionally) ────────────────────────
# All builder stages are bind-mounted read-only; no intermediate COPY layers.
RUN --mount=type=bind,from=build-pgvector,source=/tmp/pgvector,target=/bld/pgvector \
    --mount=type=bind,from=build-pgvectorscale,source=/tmp/pgvectorscale,target=/bld/pgvectorscale \
    --mount=type=bind,from=build-pglater,source=/tmp/pg_later,target=/bld/pg_later \
    --mount=type=bind,from=build-pgmq,source=/tmp/pgmq,target=/bld/pgmq \
    --mount=type=bind,from=build-safeupdate,source=/tmp/pg-safeupdate-master,target=/bld/safeupdate \
    --mount=type=bind,from=build-anon,source=/tmp/postgresql_anonymizer,target=/bld/anon \
    set -ex && \
    EXT="/usr/lib/postgresql/${POSTGRESQL_VERSION}/lib" && \
    SHARE="/usr/share/postgresql/${POSTGRESQL_VERSION}/extension" && \
    # ── pgvector ──
    if [ "${ENABLE_PGVECTOR}" = "true" ] && [ -f /bld/pgvector/vector.so ]; then \
        cp /bld/pgvector/vector.so           "${EXT}/" && \
        cp /bld/pgvector/vector.control      "${SHARE}/" && \
        cp /bld/pgvector/sql/*.sql           "${SHARE}/"; \
    fi && \
    # ── pgvectorscale ──
    if [ "${ENABLE_PGVECTORSCALE}" = "true" ]; then \
        find /bld/pgvectorscale -name "*.so" -exec cp {} "${EXT}/" \; && \
        find /bld/pgvectorscale -path "*/extension/*.control" -exec cp {} "${SHARE}/" \; && \
        find /bld/pgvectorscale -path "*/extension/*.sql"     -exec cp {} "${SHARE}/" \; 2>/dev/null || true; \
    fi && \
    # ── pg-safeupdate ──
    if [ "${ENABLE_SAFEUPDATE}" = "true" ] && [ -f /bld/safeupdate/safeupdate.so ]; then \
        cp /bld/safeupdate/safeupdate.so "${EXT}/"; \
    fi && \
    # ── pgmq ──
    if [ "${ENABLE_PGMQ}" = "true" ] && [ -f /bld/pgmq/pgmq-extension/pgmq.control ]; then \
        cp /bld/pgmq/pgmq-extension/pgmq.control "${SHARE}/" && \
        find /bld/pgmq/pgmq-extension/sql -name "*.sql" -exec cp {} "${SHARE}/" \; ; \
    fi && \
    # ── pg_later ──
    if [ "${ENABLE_PGLATER}" = "true" ]; then \
        find /bld/pg_later -name "*.so"           -exec cp {} "${EXT}/"    \; && \
        find /bld/pg_later -path "*/extension/*.control" -exec cp {} "${SHARE}/" \; && \
        find /bld/pg_later -path "*/extension/*.sql"     -exec cp {} "${SHARE}/" \; 2>/dev/null || true; \
    fi && \
    # ── anon ──
    if [ "${ENABLE_ANON}" = "true" ]; then \
        find /bld/anon -name "*.so"                    -exec cp {} "${EXT}/"    \; && \
        find /bld/anon -path "*/extension/*.control"   -exec cp {} "${SHARE}/" \; && \
        find /bld/anon -path "*/extension/*.sql"       -exec cp {} "${SHARE}/" \; 2>/dev/null || true; \
    fi

# ── STEP 3: Supercronic (architecture-aware) ──────────────────────────────────
RUN --mount=type=cache,id=supercronic-dl,target=/tmp/sc-cache \
    set -ex && \
    ARCH=$(dpkg --print-architecture) && \
    case "${ARCH}" in \
        amd64) SC="supercronic-linux-amd64" ;; \
        arm64) SC="supercronic-linux-arm64" ;; \
        *)     echo "Unsupported arch: ${ARCH}" && exit 1 ;; \
    esac && \
    DEST="/tmp/sc-cache/${SC}-${SUPERCRONIC_VERSION}" && \
    if [ ! -f "${DEST}" ]; then \
        wget -q -O "${DEST}" \
            "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/${SC}"; \
    fi && \
    install -m 0755 "${DEST}" /usr/local/bin/supercronic

# ── STEP 4: Static postgresql.conf additions + directory skeleton ─────────────
COPY ./postgresql.conf.sample /usr/share/postgresql/postgresql.conf.sample

RUN set -ex && \
    # pgBackRest directory tree (created even when disabled so mounts work)
    mkdir -p \
        /docker-entrypoint-initdb.d \
        /etc/pgbackrest/conf.d \
        /var/log/pgbackrest \
        /pgbackrest/repo \
        /pgbackrest/spool \
        /tmp/pgbackrest && \
    touch /etc/pgbackrest/pgbackrest.conf && \
    chown -R postgres:postgres \
        /etc/pgbackrest /var/log/pgbackrest /pgbackrest /tmp/pgbackrest && \
    chmod 750 /etc/pgbackrest && \
    chmod 770 /var/log/pgbackrest /pgbackrest && \
    chmod 750 /tmp/pgbackrest && \
    # pgbackrest binary permission (may not exist when disabled, skip gracefully)
    [ -f /usr/bin/pgbackrest ] && chmod 755 /usr/bin/pgbackrest || true && \
    # Static WAL / replication settings (always applied; extension preload
    # is handled dynamically by entrypoint.sh at runtime).
    printf '%s\n' \
        "wal_level = logical" \
        "wal_compression = on" \
        "max_wal_senders = 4" \
        >> /usr/share/postgresql/postgresql.conf.sample

# ── STEP 5: Application scripts ───────────────────────────────────────────────
COPY ./entrypoint.sh         /usr/local/bin/entrypoint.sh
COPY ./initdb-pgbackrest.sh  /docker-entrypoint-initdb.d/10_pgbackrest.sh
COPY ./initdb-postgis.sh      /docker-entrypoint-initdb.d/20_postgis.sh
COPY ./initdb-extensions.sh  /docker-entrypoint-initdb.d/30_extensions.sh
COPY ./update-postgis.sh     /usr/local/bin/update-postgis.sh

RUN chmod +x \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/update-postgis.sh \
        /docker-entrypoint-initdb.d/10_pgbackrest.sh \
        /docker-entrypoint-initdb.d/20_postgis.sh \
        /docker-entrypoint-initdb.d/30_extensions.sh

# ── STEP 6: Metadata ──────────────────────────────────────────────────────────
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
    CMD pg_isready -U "${POSTGRES_USER:-postgres}" || exit 1

ENTRYPOINT ["entrypoint.sh"]
CMD ["postgres"]

# OCI-standard labels (replaces legacy LABEL key=value pairs)
LABEL org.opencontainers.image.title="Homestead PostgreSQL" \
      org.opencontainers.image.description="PostgreSQL ${POSTGRESQL_VERSION} with optional extensions: pgvector, pgvectorscale, postgis, timescaledb, pgmq, pg_later, anon, pgaudit, pg_squeeze, pgroonga, pgbackrest" \
      org.opencontainers.image.authors="ItzDabbzz <dabz@homestead.systems>" \
      org.opencontainers.image.version="2.0" \
      org.opencontainers.image.source="https://github.com/itzdabbzz/homestead-postgres"