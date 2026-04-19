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
| **Supabase** | Built-in connection pooler, auth, realtime — complementary to нашей инфре. Row-level security. PostgreSQL-native. Free tier до 500MB. | Vendor lock-in на extra features (auth, realtime) — нам не нужны, используем только DB. Shared compute на cheap plans. | $25-500+ |
| **Neon** | Serverless scaling, branching (per-PR prod-like DBs), compute scales to zero. PostgreSQL-native без lock-in. | Cold start latency 1-2s (mitigated connection pooler). Russia-friendly billing? проверить. | $19-500+ |
| **Amazon RDS** | Enterprise-grade, multi-AZ, read replicas out-of-box, point-in-time recovery. | Expensive baseline ($30-50 minimum), Russia billing problematic, AWS lock-in. | $50-500+ |
| **DigitalOcean Managed DB** | Simple pricing, multi-region, automatic backups. | Less ecosystem than RDS. | $15-500+ |
| **Yandex Cloud Managed Postgres** | Russian-friendly billing, local datacenters low latency для RU users. | Less ecosystem, some features lag AWS/GCP. | ₽1500-20000+ |

**Recommendation для первой миграции:** Neon или Supabase для simplicity + branching. Если Russia billing проблема — Yandex Cloud.

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

**pg_partman на managed Postgres:** Проверить что provider supports `shared_preload_libraries` config OR community extension install. Neon supports custom extensions (request through support). Supabase — ограниченный список. RDS — поддерживает через parameter groups. Yandex Cloud — нужно проверить.

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
