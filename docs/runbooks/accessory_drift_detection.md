# Accessory Drift Detection — Auto-Detection System Runbook

## Цель

Автоматическое detection accessory image drift между declared (`config/deploy.yml`) и runtime (`docker inspect` через kamal). Drift detected → DB event opened + Telegram alert (production) + Prometheus metric. Eliminates manual DV review.

## Архитектура

- **Worker:** `AccessoryDriftDetectorWorker` (Sidekiq)
- **Schedule:** hourly cron (`0 * * * *`) via sidekiq-cron
- **Queue:** `:accessory_ops` (priority 2)
- **Service:** `AccessoryOps::DriftCheckService.call(destination:, accessory:)`
- **Storage:** `accessory_drift_events` table

## Как работает

### Per hour cycle

1. Worker запускается
2. Iterate destinations (`staging`, `production`)
3. Per destination iterate accessories (read из `config/deploy.yml`)
4. Per accessory:
   - Read declared image из `config/deploy.yml` (parse YAML)
   - Read runtime image: `kamal accessory details -d <destination> --output=json` (per ADR DEC-25)
   - Compare:
     - **Match** + open drift_event existing → close event (resolved_at, MTTR computed)
     - **Match** + no open event → no-op
     - **Mismatch** + no open event → open new drift_event, send Telegram alert (production only per BR-011), set Prometheus gauge=1
     - **Mismatch** + open event existing → idempotent NO new alert (per BR-008)

### Idempotency

Worker safe to run multiple times. Open drift_event uniqueness enforced через partial index `(destination, accessory) WHERE status='open'`.

## Schema: accessory_drift_events

| Поле | Тип | Описание |
| --- | --- | --- |
| id | UUID | PK |
| destination | varchar | staging \| production |
| accessory | varchar | db, redis, grafana, etc. |
| declared_image | varchar | Из deploy.yml |
| runtime_image | varchar | Из docker inspect |
| detected_at | timestamp | When worker detected drift |
| resolved_at | timestamp | When drift resolved (null if open) |
| status | varchar | enum [open, resolved] |
| alert_sent_at | timestamp | When Telegram alert fired |
| created_at, updated_at | timestamp | Standard |

## Alert routing

Per `alertmanager.yml` config:

| Event | Severity | Channel |
| --- | --- | --- |
| Drift open production | warning | telegram_ops |
| Drift open staging | info | telegram_info (silent в production setup) |
| Drift unresolved >24h | critical | telegram_critical + @PO |
| Drift resolved | info | telegram_info |

Alerts deduplicated за 4h window (Alertmanager `repeat_interval`).

## Manual operations

### Force drift detection cycle

```bash
# In Rails console на VPS:
docker exec -it himrate-job bundle exec rails runner "AccessoryDriftDetectorWorker.new.perform"
```

### Query open drift events

```sql
SELECT destination, accessory, declared_image, runtime_image, detected_at,
       NOW() - detected_at AS open_for
FROM accessory_drift_events
WHERE status = 'open'
ORDER BY detected_at DESC;
```

### MTTR statistics

```sql
SELECT destination, accessory,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (resolved_at - detected_at))) AS mttr_p50_seconds,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (resolved_at - detected_at))) AS mttr_p95_seconds,
       COUNT(*) AS total_events
FROM accessory_drift_events
WHERE status = 'resolved' AND detected_at > NOW() - INTERVAL '30 days'
GROUP BY destination, accessory;
```

## Sidekiq worker monitoring

### Verify worker registered

```bash
docker exec -it himrate-job bundle exec rails runner "puts Sidekiq::Cron::Job.all.map(&:name).inspect"
# Should include "AccessoryDriftDetector"
```

### Verify worker running

Check `SidekiqHealthMonitorWorker` (per ADR DEC-5) — runs every 30min, alerts critical если drift detector heartbeat stale >2h.

### Force restart worker

```bash
gh workflow run accessory-ops.yml -f destination=production -f accessory=job -f action=restart
# Wait — note: 'job' accessory not in scope. Use Sidekiq web UI manual restart instead.
```

OR via Sidekiq web UI: https://staging.himrate.com/sidekiq → Jobs → AccessoryDriftDetectorWorker → restart.

## Edge cases

### Worker missed cycle (Sidekiq down)

`SidekiqHealthMonitorWorker` alerts critical. Manual workflow trigger possible meanwhile (per `accessory_ops.md`).

### Drift detection через manual workflow trigger

Worker NOT triggered by manual operations. Worker scans declared vs runtime — if PO triggers reboot manually, drift will be detected/resolved on next hourly cycle.

### New accessory added

PR adding accessory к `deploy.yml` MUST also update workflow enum в `accessory-ops.yml` (per ADR DEC-9 process). Worker reads accessory list dynamically from deploy.yml — no code change needed.

## Related

- `accessory_ops.md` — manual workflow trigger
- `accessory_auto_remediation.md` — auto-trigger workflow at drift detection (post Flipper flag enable)
- `grafana_dashboards.md` — Drift Trend dashboard
