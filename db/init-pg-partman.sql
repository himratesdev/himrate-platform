-- TASK-039 ADR §4.2: Idempotent pg_partman extension setup.
--
-- Выполняется postgres:16 entrypoint ОДИН РАЗ при initial PGDATA creation
-- (/docker-entrypoint-initdb.d/*.sql). Для fresh environments (локальный
-- docker compose up, test DBs, future new staging/prod). Для existing
-- production/staging DB выполняется вручную после image switch — см.
-- docs/runbooks/pg_partman_recovery.md §1.
--
-- IF NOT EXISTS делает оба statement idempotent: повторный запуск (если
-- entrypoint пере-запустится) не упадёт.

CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;
