# TASK-039 ADR §4.2: Custom Postgres image с pg_partman extension
# для native monthly partitioning (trends_daily_aggregates).
#
# Base: postgres:16 (official). +postgresql-16-partman (Ubuntu apt).
# Image: ghcr.io/himratesdev/himrate-postgres:16-partman
# Build: .github/workflows/build-db-image.yml (on push to main, db/** changes)
# Deploy: config/deploy.yml accessories.db.image

FROM postgres:16

# Install pg_partman from Postgres APT repo (postgresql-16-partman package)
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-partman \
 && rm -rf /var/lib/apt/lists/*

# Extension нужно создать в DB вручную после первого запуска:
#   CREATE EXTENSION pg_partman SCHEMA partman;
# (миграция #5 partman setup требует extension пред-установленным)
