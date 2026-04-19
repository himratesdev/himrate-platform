# TASK-039 ADR §4.2: Custom Postgres image с pg_partman extension
# для native monthly partitioning (trends_daily_aggregates).
#
# Tag convention: ghcr.io/himratesdev/himrate-postgres:16-partman-v{N}.
# При любом изменении этого Dockerfile bump version в 3 местах consistently:
#   1. `FROM postgres:N.N` (если PG minor bump ниже в этом файле)
#   2. `LABEL org.opencontainers.image.version="..."` ниже в этом файле
#   3. `IMAGE_TAG` env в .github/workflows/build-db-image.yml
#   4. `accessories.db.image` tag в config/deploy.yml
# После bump: commit → CI builds new image → coordinated kamal accessory reboot.
# Explicit versioning предотвращает mutable tag drift (CR SF-1).
#
# Image: ghcr.io/himratesdev/himrate-postgres:16-partman-v1
# Build: .github/workflows/build-db-image.yml (on push to main, db/** changes)
# Deploy: config/deploy.yml accessories.db.image
#
# Совместимость данных: postgres:16.x base → same PGDATA format как official
# postgres:16. Volume himrate_pgdata mountable без миграции данных.

# Pinned minor version (CR N-2). Bump aligned с postgres:16 security patches.
FROM postgres:16.4

# OCI standard labels — links image с GitHub repo + searchable metadata (CR N-6).
LABEL org.opencontainers.image.source="https://github.com/himratesdev/himrate-platform"
LABEL org.opencontainers.image.description="PostgreSQL 16.4 с pg_partman extension для TASK-039 Trends Tab native partitioning"
LABEL org.opencontainers.image.licenses="Proprietary"
LABEL org.opencontainers.image.vendor="HimRate"
LABEL org.opencontainers.image.version="16-partman-v1"

# Install pg_partman from PostgreSQL APT repo (postgresql-16-partman package).
# Current stable в Debian bookworm: 4.7.x (supports native PG partitioning per ADR §4.2).
# pg_partman НЕ требует shared_preload_libraries (мы используем Sidekiq cron для
# run_maintenance вместо partman_bgw background worker — см. ADR §4.2 Phase B).
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-partman \
 && rm -rf /var/lib/apt/lists/*

# Build-time verification: extension control файл присутствует.
# Build FAILS если apt package broken — prevents silent "ghost" image без partman.
RUN test -f /usr/share/postgresql/16/extension/pg_partman.control \
 || (echo "ERROR: pg_partman.control not found — extension files missing" && exit 1)

# Idempotent extension init для fresh DB (production redeploys / test environments).
# Не срабатывает если DB already initialized — postgres:16 entrypoint исполняет
# *.sql из /docker-entrypoint-initdb.d только при initial PGDATA creation.
# Для existing staging/prod DB — manual execution per runbook §1.
COPY init-pg-partman.sql /docker-entrypoint-initdb.d/01-pg-partman.sql
