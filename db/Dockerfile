# TASK-039 ADR §4.2: Custom Postgres image с pg_partman extension
# для native monthly partitioning (trends_daily_aggregates).
#
# Base: postgres:16 (official, Debian bookworm). +postgresql-16-partman
# устанавливается из PostgreSQL APT repo (apt.postgresql.org).
#
# Image: ghcr.io/himratesdev/himrate-postgres:${IMAGE_VERSION}
#
# **Single source of truth для version: config/deploy.yml**
#   accessories.db.image: ghcr.io/himratesdev/himrate-postgres:<TAG>
# При bump: изменить ТОЛЬКО deploy.yml — build workflow читает оттуда +
# passes via --build-arg IMAGE_VERSION. Dockerfile LABEL получает value от
# build arg → sync guaranteed by design (no drift possible, no grep parsing).
#
# Build: .github/workflows/build-db-image.yml (on push to main,
# db/** or config/deploy.yml changes).
# Local build example:
#   docker build --build-arg IMAGE_VERSION=test-local -t himrate-postgres:test db/
# Deploy: kamal accessory reboot db -d <dest> — volume persistent,
# данные сохраняются через reboot.
#
# Layer ordering optimized для cache efficiency (CR N-1): expensive apt install
# перед variable ARG/LABEL layers → version bump invalidates only last few
# trivial layers (LABEL), apt install layer stays cached (~2 min saved/build).

# Minor version pinned для security patching control. Dependabot docker
# ecosystem (.github/dependabot.yml) auto-PR на postgres:16.x bumps.
FROM postgres:16.4

# === Stable layers (cached across version bumps) ===
#
# Install pg_partman from PostgreSQL APT repo (postgresql-16-partman package).
# PINNED version: pg_partman 5.4.3 (latest stable as of 2026-04).
# ADR §4.2: native PostgreSQL RANGE partitioning. pg_partman НЕ требует
# shared_preload_libraries — используем Sidekiq cron для partman.run_maintenance.
#
# pg_partman 5.x API (breaking changes от 4.x):
#   • p_interval: PostgreSQL standard interval format ('1 month'), не shortcut 'monthly'
#   • p_type: default 'range', keyword 'native' removed
# db/migrate/*_partition_trends_daily_aggregates.rb использует 5.x syntax.
#
# Version pinning: exact version (5.4.3-1.pgdg12+1) для reproducible builds.
# При bump — edit этот line + deploy.yml tag (16-partman-v<N>) + CR review.
# Defense против breaking changes 5.x → 6.x whenever.
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-partman=5.4.3-1.pgdg12+1 \
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

# === Variable layers (invalidated on version bump) ===
#
# IMAGE_VERSION — forced from --build-arg (no default). CI must provide
# value, extracted from deploy.yml. Prevents silent build без корректной
# version metadata → fail fast если workflow не passes --build-arg.
ARG IMAGE_VERSION

# Validate что IMAGE_VERSION non-empty (--build-arg provided).
# Fails loudly если someone runs `docker build db/` без build-arg.
RUN [ -n "$IMAGE_VERSION" ] \
 || (echo "ERROR: IMAGE_VERSION build arg required — pass via --build-arg IMAGE_VERSION=..." && exit 1)

# OCI standard labels — links image с GitHub repo + searchable metadata.
# version получает значение от build arg (single source = deploy.yml).
LABEL org.opencontainers.image.source="https://github.com/himratesdev/himrate-platform"
LABEL org.opencontainers.image.description="PostgreSQL 16.4 с pg_partman extension для TASK-039 Trends Tab native partitioning"
LABEL org.opencontainers.image.licenses="Proprietary"
LABEL org.opencontainers.image.vendor="HimRate"
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
