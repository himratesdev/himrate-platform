# Database + Redis Scaling Plan

## Текущая архитектура (MVP → early scale)

**Один VPS** (194.135.85.159, Time4VPS, 3 cores / 8GB RAM / 80GB disk):

- **PostgreSQL 16.4 + pg_partman** — один Kamal accessory `db`, две database внутри:
  - `himrate_production` для prod
  - `himrate_staging` для staging
  - Single `POSTGRES_PASSWORD`, same user `himrate`, host `himrate-db:5432`
  - Persistent volume `himrate_pgdata:/var/lib/postgresql/data`
- **Redis 7 (Redis Stack)** — один accessory `redis`, два DB index:
  - `redis://himrate-redis:6379/0` для prod
  - `redis://himrate-redis:6379/1` для staging
  - Persistent volume `himrate_redis:/data`, `appendonly yes`

**Обоснование shared accessories:** на 8GB VPS два отдельных Postgres instances потребили бы ~2GB RAM только на PG processes; logical DB separation даёт acceptable isolation для MVP при минимальном resource footprint. Blast radius (Postgres down = оба env down) приемлем на этапе когда prod ещё не запущен в production traffic mode.

## Migration triggers (когда мигрировать)

Следующий шаг — **managed PostgreSQL + managed Redis для production**, staging остаётся на VPS.

Триггеры к миграции (любой из):

| Trigger | Threshold | Measurement |
|---|---|---|
| Postgres DB size | > 30 GB | `SELECT pg_size_pretty(pg_database_size('himrate_production'))` |
| Sustained IOPS | > 500 write IOPS p95 за 24h | `iostat` на VPS или Grafana |
| Connection pool saturation | > 80% connections used regularly | `pg_stat_activity` + Rails connection pool metrics |
| Memory pressure | Postgres RSS > 4 GB (50% VPS RAM) | `docker stats himrate-db` |
| Backup window | pg_dump > 15 min | Backup job runtime |
| Real MAU | > 1000 monthly active users | App analytics |
| Revenue | > $5k MRR | Business metric (reliability ROI becomes material) |

## Managed options — оценка

### PostgreSQL

| Provider | Pros | Cons | ~$/mo |
|---|---|---|---|
| **Neon** | Serverless scaling, branching (per-PR prod-like DBs), compute scales to zero. PostgreSQL-native без lock-in. Supports custom extensions (pg_partman via support request). EU regions available (Frankfurt, Amsterdam). | Cold start latency 1-2s (mitigated connection pooler). | $19-500+ |
| **Supabase** | Built-in connection pooler, auth, realtime — complementary to нашей инфре. Row-level security. PostgreSQL-native. Free tier до 500MB. | Vendor lock-in на extra features (auth, realtime) — нам не нужны, используем только DB. Shared compute на cheap plans. Fixed extension allowlist (pg_partman требует проверки через support). | $25-500+ |
| **Hetzner Cloud Managed** | EU datacenters (Falkenstein/Nuremberg), low latency для VPS в Lithuania. Simple EUR pricing. | Younger offering, less mature than RDS. | €20-200+ |
| **DigitalOcean Managed DB** | Simple pricing, multi-region, automatic backups. Frankfurt DC near VPS. | Less ecosystem than RDS. Extension allowlist. | $15-500+ |
| **Amazon RDS (eu-central-1)** | Enterprise-grade, multi-AZ, read replicas out-of-box, point-in-time recovery. Frankfurt region низкой latency. | Expensive baseline ($30-50 minimum), AWS lock-in, complexity. | $50-500+ |

**Исключён из списка:** Yandex Cloud Managed Postgres. Причины: (a) billing restrictions post-2022 — Lithuania entity не может reliably оплачивать, international cards отклоняются; (b) pg_partman НЕ в default extension allowlist, custom extensions требуют support ticket без SLA; (c) pricing RUB-denominated + exchange rate volatility. Technical fit secondary — billing blocker decisive.

**Recommendation для первой миграции:** Neon (primary) или Hetzner Cloud Managed (если хотим максимально EU-local data residency). Оба поддерживают pg_partman + PostgreSQL-native без vendor lock-in.

### Redis

| Provider | Pros | Cons | ~$/mo |
|---|---|---|---|
| **Upstash** | Serverless (pay per request), global replication, REST API. | Cold connections add 5-20ms latency (ok для cache, проблема для hot tight loops). | $0 free tier → $50+ |
| **Redis Cloud** | Official Redis company, includes Redis Stack (same as accessory), enterprise features. | Pricier baseline, less flexibility. | $30-500+ |
| **DigitalOcean Managed Redis** | Simple, predictable pricing. | Less advanced features. | $15-250+ |

**Recommendation:** Upstash для cost efficiency, migrate к Redis Cloud если hit serverless latency walls.

## Migration procedure (когда triggers сработают)

**Zero-downtime migration требует:**

1. **Provision managed instance** (Neon/Supabase/whatever) — создать DB с тем же именем (`himrate_production`).
2. **Snapshot + restore:**
   - `pg_dump -Fc himrate_production > snapshot.dump` на VPS
   - `pg_restore -d <managed-url>/himrate_production snapshot.dump`
3. **Logical replication setup** для catch-up (optional, для zero-downtime):
   - Configure logical replication от VPS Postgres → managed
   - Wait for lag < 1s
4. **Cutover window** (maintenance):
   - Stop Rails app (Kamal `app stop`)
   - Final sync (wait для replication catch-up OR re-dump tail)
   - Update `PRODUCTION_DATABASE_URL` secret (or construct inline в ci.yml) к managed URL
   - `kamal redeploy -d production` — Rails подхватывает новую DATABASE_URL
   - Health check + smoke test
5. **Keep VPS Postgres running неделю** для rollback option, затем shutdown db accessory, освободив resources для prod web/job containers.

**pg_partman на managed Postgres:** Проверить что provider supports `shared_preload_libraries` config OR community extension install. Neon supports custom extensions (request through support). Supabase — ограниченный список (проверять через support). RDS — поддерживает через parameter groups. Hetzner — PostgreSQL-native extension install (need docs check).

## Rollback procedure (если cutover failed)

**Trigger:** health checks fail после cutover, smoke test detects broken behavior, replication lag stuck, managed DB unavailable, etc.

Rollback steps (в порядке execution):

1. **IMMEDIATE — Stop app на managed DB**
   ```bash
   kamal app stop -d production
   ```
   Prevents further writes к managed, которые не будут replicated обратно.

2. **Revert DATABASE_URL secret**
   - GitHub repo settings → Secrets → `KAMAL_REGISTRY_PASSWORD` (or inline construction в ci.yml):
   - Вернуть к VPS DB URL: `postgres://himrate:${POSTGRES_PASSWORD}@himrate-db:5432/himrate_production`
   - OR comment out Construct DATABASE_URL step в ci.yml если inline

3. **Redeploy c old DATABASE_URL**
   ```bash
   kamal redeploy -d production
   ```
   Rails containers подхватят старую DATABASE_URL, VPS Postgres up-and-healthy (ещё не shutdown per §5).

4. **Data reconciliation** (если managed DB получила записи во время cutover):
   - `pg_dump` managed DB only-data delta между cutover time и now
   - `psql` на VPS DB — apply delta через manual SQL review
   - ИЛИ accept data loss за cutover window (если short, low-write)

5. **Root cause analysis**
   - Why cutover failed? (connectivity, extension, replication lag, perm issues)
   - Fix root cause ДО второй попытки migration
   - Schedule second attempt с improved procedure

6. **Leave VPS Postgres running** до успешного cutover (не shutdown preemptively).

**Rollback acceptable time window:** Должен быть completed в 30 минут после cutover detection. Longer = больше data loss risk на managed side. Maintenance window должен include rollback buffer: actual cutover time × 2.

**Pre-cutover checklist (reduces rollback probability):**
- [ ] Dry-run migration на staging-like environment
- [ ] Verify pg_partman extension work post-restore (`SELECT * FROM partman.parent;`)
- [ ] Test application health endpoints на managed DB (manual run с DATABASE_URL override)
- [ ] Confirm SSL cert validity (managed DB обычно требует sslmode=verify-full)
- [ ] Backup VPS DB snapshot перед cutover (extra safety net)
- [ ] Team on-call available во время maintenance window

## Staging остаётся на VPS

Staging — полигон для экспериментов, может иметь "dirty infra" (PO requirement). VPS accessories остаются для staging даже после prod migration:
- Resource freed от prod Postgres → используется staging + prod app containers
- Staging не требует enterprise reliability — VPS ок
- Faster iteration без cloud billing overhead для test data

## Trigger ownership

- **Monitoring:** `/docs/runbooks/monitoring.md` (to be created) — какие metrics, где dashboard, alerts
- **Decision owner:** PO + SA review вместе каждый sprint (weekly)
- **Migration execution:** Architect + Dev + DevOps (1-day dedicated cutover sprint)

## Related runbooks

- `docs/runbooks/kamal_local_deploy.md` — Kamal credential management (affects migration secrets handling)
- `docs/runbooks/pg_partman_recovery.md` — pg_partman extension recovery (applies both to VPS and managed если supported)
