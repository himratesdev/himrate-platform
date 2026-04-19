# pg_partman Recovery Runbook

**Контекст:** TASK-039 Trends Tab использует `pg_partman` для управления partition-layer таблицы `trends_daily_aggregates` (monthly, retention 2y). Migration `20260419100005_partition_trends_daily_aggregates.rb` использует `disable_ddl_transaction!` (обязательное требование `partman.create_parent`), поэтому partial failure может оставить DB в несогласованном состоянии.

Этот документ — recovery procedures для ops/DBA.

---

## 1. Предварительное требование: pg_partman extension установлен

### Проверка

```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_partman';
```

- **Пусто** → extension не установлен → миграция #5 raise в production (правильное поведение).
- **Возвращает row** → extension установлен, миграция продолжит выполнение.

### Установка

Extension files уже установлены в Docker image `ghcr.io/himratesdev/himrate-postgres:16-partman` (см. `db/Dockerfile`). Нужно только создать extension в целевой DB.

**Для fresh DB (новый environment):** автоматически через `/docker-entrypoint-initdb.d/01-pg-partman.sql` (выполняется при initial PGDATA creation).

**Для existing DB (staging/prod после image switch):**

```bash
# 1. Pull/reboot accessory с новым image:
kamal accessory reboot db -d staging  # или production

# 2. Подключиться к DB контейнеру и создать extension:
docker exec himrate-db psql -U himrate -d himrate_staging -c \
  "CREATE SCHEMA IF NOT EXISTS partman; \
   CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;"

# 3. Verify:
docker exec himrate-db psql -U himrate -d himrate_staging -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_partman';"
# Expected: строка с pg_partman + версия (4.7.x или 5.x)
```

**Если image ещё не собран (pre-merge PR #79):**

На managed DB / облачных провайдерах (AWS RDS / GCP Cloud SQL) — через админ-консоль,
где pg_partman доступен как managed extension. Для self-hosted без custom image —
временно `apt-get install postgresql-16-partman` внутри running контейнера (НЕ рекомендуется:
не сохраняется между reboots, нестабильно, требует rebuild image для долгосрочного использования).

**Примечание:** pg_partman НЕ требует `shared_preload_libraries` — в отличие от pg_cron,
pg_partman это обычное extension. В HimRate мы используем Sidekiq cron для
`partman.run_maintenance` (ADR §4.2 Phase B) вместо `partman_bgw` background worker.

Проверка версии: `pg_partman >= 4.7` для native partitioning support.

---

## 2. Scenario A: Migration #5 упала на `partman.create_parent`

**Симптом:** Миграция прервалась с `ActiveRecord::StatementInvalid` после того как `CREATE EXTENSION` сработал, но `create_parent` упал (out of memory, long-running transaction conflict, etc.).

**Состояние DB:**
- `trends_daily_aggregates` существует как native PARTITIONED parent (из миграции #1)
- `trends_daily_aggregates_default` partition существует (из миграции #1)
- `partman.part_config` — **нет записи** (create_parent не завершился)
- Monthly partitions — **не созданы**

### Recovery

```sql
-- 1. Проверить состояние partman
SELECT parent_table, retention, retention_keep_table
FROM partman.part_config
WHERE parent_table = 'public.trends_daily_aggregates';
-- Expected: no rows (если create_parent упал до INSERT)

-- 2. Повторно запустить create_parent вручную
SELECT partman.create_parent(
  p_parent_table => 'public.trends_daily_aggregates',
  p_control => 'date',
  p_type => 'native',
  p_interval => 'monthly',
  p_premake => 4,
  p_start_partition => to_char(CURRENT_DATE - INTERVAL '3 months', 'YYYY-MM-01')
);

-- 3. Настроить retention
UPDATE partman.part_config
SET retention = '2 years',
    retention_keep_table = false,
    retention_keep_index = false
WHERE parent_table = 'public.trends_daily_aggregates';

-- 4. Проверить созданные partitions
SELECT schemaname, tablename
FROM pg_tables
WHERE tablename LIKE 'trends_daily_aggregates_p%'
ORDER BY tablename;
-- Expected: 8 partitions (3 прошлых + 4 будущих + default)
```

### Отметить миграцию выполненной в Rails

```bash
# Если миграция #5 marked as pending в schema_migrations
docker compose exec web rails runner "
  ActiveRecord::SchemaMigration.create!(version: '20260419100005') unless
    ActiveRecord::SchemaMigration.find_by(version: '20260419100005')
"
```

---

## 3. Scenario B: `partman.create_parent` прошёл, но `UPDATE part_config` упал

**Симптом:** Partitions созданы, но retention policy не применена.

**Состояние:**
- `partman.part_config` содержит row для `trends_daily_aggregates`
- `retention` = NULL (default, no auto-drop)

### Recovery

```sql
UPDATE partman.part_config
SET retention = '2 years',
    retention_keep_table = false,
    retention_keep_index = false
WHERE parent_table = 'public.trends_daily_aggregates';

-- Повторно отметить миграцию #5 как выполненную (см. выше)
```

---

## 4. Scenario C: Rollback — полное удаление partitioning

**Контекст:** Migration #5 `def down` marked `ActiveRecord::IrreversibleMigration` — automated rollback недопустим из-за data loss risk. Ниже — manual procedure.

**⚠️ Критично:** сделать `pg_dump` данных ПЕРЕД любым rollback.

### Шаги

```bash
# 1. Backup данных из всех partitions
pg_dump -h <db_host> -U <user> -d <db> \
  --table='trends_daily_aggregates_*' \
  --data-only \
  > /tmp/trends_backup_$(date +%Y%m%d).sql

# 2. Подсчитать строки для аудита
psql -c "SELECT count(*) FROM trends_daily_aggregates"
# Save output
```

```sql
-- 3. Отключить pg_partman management (не-destructive)
DELETE FROM partman.part_config
WHERE parent_table = 'public.trends_daily_aggregates';

-- 4. Unpart или drop (выбор):

-- Option A: unpart (консолидация в unpartitioned table, pg_partman >= 4.7)
-- SELECT partman.undo_partition(
--   p_parent_table => 'public.trends_daily_aggregates',
--   p_batch_count => 100
-- );

-- Option B: полное удаление (если нужно revert миграцию #1 тоже)
-- DROP TABLE trends_daily_aggregates CASCADE;
-- ... + rails db:rollback STEP=7 для остальных миграций

-- 5. Откатить pg_partman расширение (опционально, только если больше не нужно)
-- DROP EXTENSION pg_partman CASCADE;
```

### Rails schema_migrations cleanup

```bash
docker compose exec web rails runner "
  ActiveRecord::SchemaMigration.where(version: [
    '20260419100001', '20260419100005'
  ]).destroy_all
"
```

---

## 5. Monitoring & Health Checks

### Проверка что partman работает

```sql
-- 1. Partitions создаются по cron (premake=4 будущих всегда)
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE tablename LIKE 'trends_daily_aggregates_p%'
ORDER BY tablename DESC
LIMIT 10;

-- 2. Старые partitions drop согласно retention (2y)
SELECT min(tablename) AS oldest_partition
FROM pg_tables
WHERE tablename LIKE 'trends_daily_aggregates_p%';
-- Expected: partition за last 24 months, ничего старше

-- 3. Default partition — пустой (safety net)
SELECT count(*) FROM trends_daily_aggregates_default;
-- Expected: 0 (production). Non-zero → partition coverage gap
```

### Default partition accumulation (архитектурный caveat)

**Важно:** `trends_daily_aggregates_default` partition создана в migration #1 declaratively. Migration #5 `create_parent` вызывается с `p_default_table => false` — pg_partman использует existing default, НЕ управляет ею.

**Последствия:**
- Retention policy (2 years) **НЕ применяется** к rows в default partition. pg_partman drop'ает только старые monthly partitions (`trends_daily_aggregates_p*`).
- Active window: current-3 до current+4 месяцев (7 months coverage via `p_premake=4` + `p_start_partition` offset). Rows вне окна landing в default.

**Когда default получает rows (ожидаемые и неожиданные):**
- 🔴 **Future INSERTs без premake-расширения:** если partman cron не успевает создать новые monthly partitions. Mitigation: Sidekiq cron `partman.run_maintenance` ежедневно (Phase B).
- 🔴 **Backfill старых данных > 3 месяцев назад:** `rake trends:backfill_aggregates` с датами вне окна → rows в default. Mitigation: backfill ТОЛЬКО в active window; для historical imports — manual `partman.create_parent` с historical start_partition.
- 🔴 **Edge-case recovery scenarios:** stream.online events с `started_at` из far past (broadcaster schedule error, TZ bug) — rare но possible.

**Detection (add к monthly ops checklist):**

```sql
-- Baseline: production healthy state = 0 rows в default
SELECT COUNT(*) AS default_row_count,
       MIN(date) AS oldest_date,
       MAX(date) AS newest_date
FROM trends_daily_aggregates_default;

-- Non-zero? Investigate:
-- 1. oldest_date < current - 3 months → backfill drift. Fix: create historical partition + move rows.
-- 2. newest_date > current + 4 months → premake gap. Fix: ensure partman cron running, run maintenance manually.
-- 3. scattered → data integrity issue (bogus dates в source).
```

**Mitigation для routine backfills:**

Если backfill required за period > 3 months назад, pre-create partition:

```sql
-- Example: backfill Jan 2025 data
SELECT partman.create_parent(
  p_parent_table => 'public.trends_daily_aggregates',
  p_control => 'date',
  p_interval => '1 month',
  p_start_partition => '2025-01-01',
  p_default_table => false
);
-- Then run rake trends:backfill_aggregates для Jan 2025
```

Альтернатива (не рекомендуется для routine): partman не knows об этой partition если create_parent дважды для same parent — нужен `partman.partition_data_proc('public.trends_daily_aggregates')` чтобы migrate rows из default в новые partitions.

### Sidekiq cron для partman maintenance

В `config/schedule.yml` (или эквивалент):

```yaml
# Ежедневно запускать partman maintenance (creates premake, drops retention)
trends_partman_maintenance:
  cron: "0 2 * * *"  # 02:00 UTC ежедневно
  class: "TrendsPartmanMaintenanceWorker"  # TBD в Phase B
```

Phase B включает `TrendsPartmanMaintenanceWorker` который вызывает `SELECT partman.run_maintenance('public.trends_daily_aggregates')`.

---

## 6. Контакты & эскалация

- **Owner:** TASK-039 Dev Agent / Platform team
- **Эскалация:** если recovery procedures не помогают — escalate к DBA consultant с pg_dump backup в руках
- **Related ADR:** §4.2 partition strategy, §4.14 extensible attribution

---

## История

| Дата | Автор | Изменение |
|------|-------|-----------|
| 2026-04-19 | Dev Agent (TASK-039 PR #78 CR iter 6) | Первая версия — response на Production Gate W-3 |
