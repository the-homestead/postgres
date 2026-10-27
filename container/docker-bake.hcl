# docker-bake.hcl
# Build with:  docker buildx bake [target]
# Examples:
#   docker buildx bake                        # builds "full" (default)
#   docker buildx bake minimal                # bare-bones image
#   docker buildx bake vector                 # AI/vector workloads
#   docker buildx bake analytics              # time-series + geo
#   docker buildx bake full minimal vector    # all three in parallel
#
# Override variables:
#   REPOSITORY=myimage TAG=dev docker buildx bake full

##############################################################################
# Variables — override via environment or --set flag
##############################################################################
variable "POSTGRESQL_VERSION" { default = "18" }

# REGISTRY   = OneDev host + project path   (matches the OneDev UI: git.myhm.space/homestead/postgres)
# REPOSITORY = image name within the project (the <repository> slot in OneDev's push URL)
# Final ref:  git.myhm.space/homestead/postgres/<repository>:<tag>
variable "REGISTRY"   { default = "git.myhm.space/homestead/postgres" }
variable "REPOSITORY" { default = "pg18" }
variable "TAG"        { default = "latest_ssl" }

# Individual extension version pins
variable "PGVECTOR_VERSION"      { default = "0.8.2"   }
variable "PGVECTORSCALE_VERSION" { default = "0.9.0"   }
variable "PGLATER_VERSION"       { default = "0.4.0"   }
variable "PGMQ_VERSION"          { default = "v1.11.0" }
variable "ANON_VERSION"          { default = "3.0.13"  }
variable "TIMESCALEDB_VERSION"   { default = "2.25.1"  }
variable "SUPERCRONIC_VERSION"   { default = "v0.2.43" }

##############################################################################
# Default group
##############################################################################
group "default" {
  targets = ["full"]
}

##############################################################################
# Base target
##############################################################################
target "_base" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]

  args = {
    POSTGRESQL_VERSION    = POSTGRESQL_VERSION
    PGVECTOR_VERSION      = PGVECTOR_VERSION
    PGVECTORSCALE_VERSION = PGVECTORSCALE_VERSION
    PGLATER_VERSION       = PGLATER_VERSION
    PGMQ_VERSION          = PGMQ_VERSION
    ANON_VERSION          = ANON_VERSION
    TIMESCALEDB_VERSION   = TIMESCALEDB_VERSION
    SUPERCRONIC_VERSION   = SUPERCRONIC_VERSION
  }

  # Cache dirs are set per-target below to avoid write conflicts when building in parallel
}

##############################################################################
# Named build targets
##############################################################################

# ── full ─────────────────────────────────────────────────────────────────────
target "full" {
  inherits  = ["_base"]
  cache-from = ["type=local,src=/tmp/buildx-cache-afull"]
  cache-to   = ["type=local,dest=/tmp/buildx-cache-afull,mode=max"]
  tags = [
    "${REGISTRY}/${REPOSITORY}:${TAG}",
    "${REGISTRY}/${REPOSITORY}:${TAG}-full",
    "${REGISTRY}/${REPOSITORY}:pg${POSTGRESQL_VERSION}-full",
  ]
  args = {
    ENABLE_PGVECTOR      = "true"
    ENABLE_PGVECTORSCALE = "true"
    ENABLE_PGLATER       = "true"
    ENABLE_PGMQ          = "true"
    ENABLE_ANON          = "true"
    ENABLE_SAFEUPDATE    = "true"
    ENABLE_TIMESCALEDB   = "true"
    ENABLE_POSTGIS       = "true"
    ENABLE_PGCRON        = "true"
    ENABLE_PGAUDIT       = "true"
    ENABLE_PGSQUEEZE     = "true"
    ENABLE_PGROONGA      = "true"
    ENABLE_PGBACKREST    = "true"
  }
}

# ── minimal ───────────────────────────────────────────────────────────────────
target "minimal" {
  inherits  = ["_base"]
  cache-from = ["type=local,src=/tmp/buildx-cache-minimal"]
  cache-to   = ["type=local,dest=/tmp/buildx-cache-minimal,mode=max"]
  tags = [
    "${REGISTRY}/${REPOSITORY}:${TAG}-minimal",
    "${REGISTRY}/${REPOSITORY}:pg${POSTGRESQL_VERSION}-minimal",
  ]
  args = {
    ENABLE_PGVECTOR      = "false"
    ENABLE_PGVECTORSCALE = "false"
    ENABLE_PGLATER       = "false"
    ENABLE_PGMQ          = "false"
    ENABLE_ANON          = "false"
    ENABLE_SAFEUPDATE    = "true"
    ENABLE_TIMESCALEDB   = "false"
    ENABLE_POSTGIS       = "false"
    ENABLE_PGCRON        = "true"
    ENABLE_PGAUDIT       = "true"
    ENABLE_PGSQUEEZE     = "false"
    ENABLE_PGROONGA      = "false"
    ENABLE_PGBACKREST    = "true"
  }
}

# ── vector ────────────────────────────────────────────────────────────────────
target "vector" {
  inherits  = ["_base"]
  cache-from = ["type=local,src=/tmp/buildx-cache-vector"]
  cache-to   = ["type=local,dest=/tmp/buildx-cache-vector,mode=max"]
  tags = [
    "${REGISTRY}/${REPOSITORY}:${TAG}-vector",
    "${REGISTRY}/${REPOSITORY}:pg${POSTGRESQL_VERSION}-vector",
  ]
  args = {
    ENABLE_PGVECTOR      = "true"
    ENABLE_PGVECTORSCALE = "true"
    ENABLE_PGLATER       = "true"
    ENABLE_PGMQ          = "true"
    ENABLE_ANON          = "false"
    ENABLE_SAFEUPDATE    = "true"
    ENABLE_TIMESCALEDB   = "false"
    ENABLE_POSTGIS       = "false"
    ENABLE_PGCRON        = "true"
    ENABLE_PGAUDIT       = "true"
    ENABLE_PGSQUEEZE     = "true"
    ENABLE_PGROONGA      = "false"
    ENABLE_PGBACKREST    = "true"
  }
}

# ── analytics ─────────────────────────────────────────────────────────────────
target "analytics" {
  inherits  = ["_base"]
  cache-from = ["type=local,src=/tmp/buildx-cache-analytics"]
  cache-to   = ["type=local,dest=/tmp/buildx-cache-analytics,mode=max"]
  tags = [
    "${REGISTRY}/${REPOSITORY}:${TAG}-analytics",
    "${REGISTRY}/${REPOSITORY}:pg${POSTGRESQL_VERSION}-analytics",
  ]
  args = {
    ENABLE_PGVECTOR      = "true"
    ENABLE_PGVECTORSCALE = "false"
    ENABLE_PGLATER       = "false"
    ENABLE_PGMQ          = "false"
    ENABLE_ANON          = "false"
    ENABLE_SAFEUPDATE    = "true"
    ENABLE_TIMESCALEDB   = "true"
    ENABLE_POSTGIS       = "true"
    ENABLE_PGCRON        = "true"
    ENABLE_PGAUDIT       = "true"
    ENABLE_PGSQUEEZE     = "true"
    ENABLE_PGROONGA      = "false"
    ENABLE_PGBACKREST    = "true"
  }
}

# ── dev ───────────────────────────────────────────────────────────────────────
target "dev" {
  inherits  = ["_base"]
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/${REPOSITORY}:dev"]
  cache-to  = ["type=local,dest=/tmp/buildx-cache,mode=max"]
  args = {
    ENABLE_PGVECTOR      = "true"
    ENABLE_PGVECTORSCALE = "false"
    ENABLE_PGLATER       = "true"
    ENABLE_PGMQ          = "true"
    ENABLE_ANON          = "false"
    ENABLE_SAFEUPDATE    = "true"
    ENABLE_TIMESCALEDB   = "true"
    ENABLE_POSTGIS       = "true"
    ENABLE_PGCRON        = "true"
    ENABLE_PGAUDIT       = "true"
    ENABLE_PGSQUEEZE     = "true"
    ENABLE_PGROONGA      = "false"
    ENABLE_PGBACKREST    = "true"
  }
}

# ── ci ────────────────────────────────────────────────────────────────────────
target "ci" {
  inherits  = ["_base"]
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/${REPOSITORY}:ci-${TAG}"]
  cache-to  = ["type=inline"]
  args = {
    ENABLE_PGVECTOR      = "true"
    ENABLE_PGVECTORSCALE = "false"
    ENABLE_PGLATER       = "false"
    ENABLE_PGMQ          = "true"
    ENABLE_ANON          = "false"
    ENABLE_SAFEUPDATE    = "true"
    ENABLE_TIMESCALEDB   = "false"
    ENABLE_POSTGIS       = "false"
    ENABLE_PGCRON        = "true"
    ENABLE_PGAUDIT       = "true"
    ENABLE_PGSQUEEZE     = "false"
    ENABLE_PGROONGA      = "false"
    ENABLE_PGBACKREST    = "false"
  }
}

##############################################################################
# Convenience group — build all production variants in parallel
##############################################################################
group "all" {
  targets = ["full", "minimal", "vector", "analytics"]
}
