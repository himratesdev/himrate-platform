# TASK-039 ADR §4.2: Custom Postgres image с pg_partman extension
# для native monthly partitioning (trends_daily_aggregates).
#
# Base: postgres:16 (official, Debian bookworm). +postgresql-16-partman
# устанавливается из официального PostgreSQL APT repo который уже настроен
# в postgres:16 image (apt.postgresql.org).
#
# Image: ghcr.io/himratesdev/himrate-postgres:16-partman
# Build: .github/workflows/build-db-image.yml (on push to main, db/** changes)
# Deploy: config/deploy.yml accessories.db.image
#
# Совместимость данных: postgres:16 base → same PGDATA format как official
# postgres:16. Volume himrate_pgdata mountable без миграции данных.

FROM postgres:16

# Install pg_partman from PostgreSQL APT repo (postgresql-16-partman package).
# Current stable: 4.7.x (supports native PG partitioning per ADR §4.2).
# Future version bump: если потребуется pg_partman 5.x, обновить этот Dockerfile +
# rebuild + coordinated reboot через runbook (docs/runbooks/pg_partman_recovery.md).
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-partman \
 && rm -rf /var/lib/apt/lists/*

# Verify extension files installed — build FAILS если package не поставил control file.
# Prevents silent image build без pg_partman (costly-to-debug prod breakage).
RUN test -f /usr/share/postgresql/16/extension/pg_partman.control \
 || (echo "ERROR: pg_partman.control not found — extension files missing" && exit 1)

# Extension создаётся в DB при первом запуске через автоматический init script
# (/docker-entrypoint-initdb.d). Для existing DB после image switch — manual:
#   CREATE SCHEMA IF NOT EXISTS partman;
#   CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;
# См. docs/runbooks/pg_partman_recovery.md для полной procedure.

# Idempotent extension init для fresh DB (production redeploys / test environments).
# Не срабатывает если DB already initialized — postgres:16 entrypoint исполняет
# *.sql из /docker-entrypoint-initdb.d только при initial PGDATA creation.
COPY init-pg-partman.sql /docker-entrypoint-initdb.d/01-pg-partman.sql
