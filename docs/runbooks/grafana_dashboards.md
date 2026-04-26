# Grafana Dashboards Reference

## Доступ

URL: https://grafana.himrate.com

### Authentication

**Primary (SSO):** Click "Sign in with Google" → Google OAuth flow → auto-create user with Admin role (FR-077, BR-022).

Email domain restricted к `himrate.com` (config `GF_AUTH_GENERIC_OAUTH_ALLOWED_DOMAINS=himrate.com`). Other emails rejected.

**Fallback (Basic Auth):** username/password из repo secrets `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`. Use только если SSO down.

## Dashboards (HimRate folder)

### 1. Drift Trend (`/d/drift-trend`)

**Назначение:** Timeline open drift events, MTTR distribution, top accessories by drift count.

**Panels:**
- Active Drift Events timeline (gauge per destination/accessory: 1=open, 0=closed)
- MTTR p50/p95 (24h window) — gauge с thresholds (green <30min, yellow 30-2h, red >2h)
- Top Accessories by Drift Count (7d) — donut chart

**Query examples:**
- `accessory_drift_active{destination="production"}` — current open drift production
- `histogram_quantile(0.95, sum(rate(accessory_drift_mttr_seconds_bucket[24h])) by (le))` — MTTR p95

### 2. Operations Frequency (`/d/operations-frequency`)

**Назначение:** Workflow operations count, success rate, failure breakdown.

**Panels:**
- Operations per Accessory/Action (24h timeline)
- Success Rate gauge (24h, thresholds: red <80%, yellow 80-95%, green >95%)
- Failure Breakdown pie chart (7d)

**Use cases:** spot operational instability (часто rebooting accessory = underlying issue).

### 3. MTTR (`/d/mttr`)

**Назначение:** Mean Time To Resolution per accessory + distribution + trends.

**Panels:**
- MTTR p50/p95 per Accessory (24h timeseries)
- MTTR Distribution Histogram (7d)

**Use cases:** track improvement over time, identify worst offenders.

### 4. Accessory Health Overview (`/d/accessory-health-overview`)

**Назначение:** At-a-glance current state всех accessories.

**Panels:**
- Table per (destination, accessory): drift_active, health_failures_total, rollback_total

**Use cases:** quick triage at incident response start.

### 5. Logs Explorer (`/d/logs-explorer`)

**Назначение:** Unified log query across all containers via Loki.

**Variable:** Container (multi-select dropdown, populated via `label_values(container)`)

**LogQL examples:**
- `{container="himrate-web-staging-..."} |= "error"` — Rails app errors
- `{container=~"himrate-job.*"} |= "AccessoryDriftDetector"` — drift detector worker logs
- `{container="himrate-prometheus"} |~ "(?i)warning"` — Prometheus warnings

**Retention:** 30 days local Loki (per ADR DEC-15).

### 6. Cost Attribution (`/d/cost-attribution`)

**⚠️ Pre-launch dormant:** показывает zeros до момента когда `revenue_baseline` table populated post-launch.

**Назначение:** Estimated revenue lost from accessory downtime.

**Panels:**
- Estimated Revenue Lost (USD) timeseries per accessory
- Total Downtime Cost (30d) stat
- Downtime Duration Histogram

**Activation steps post-launch:**
1. Populate `revenue_baseline` table из financial pipeline (manual SQL OR automated job)
2. `CostAttribution::DowntimeCostCalculator` начинает returning positive values
3. `CostAttribution::DailyAggregatorWorker` daily aggregates → Prometheus metrics
4. Dashboard auto-displays real numbers

## Adding new dashboard

1. Create dashboard в Grafana UI (logged as Admin)
2. Save JSON: dashboard menu → Settings → JSON Model → copy
3. Add file `grafana/dashboards/<name>.json` в repo
4. Commit + PR
5. After deploy: Grafana auto-loads via provisioning (`grafana/provisioning/dashboards/dashboards.yml`)

⚠️ Manual UI dashboard edits NOT persisted (per BR-016 — IaC principle). Always commit JSON to repo.

## Datasources

| Name | Type | URL | Used by |
| --- | --- | --- | --- |
| Prometheus | prometheus | http://prometheus:9090 | All metric dashboards |
| Loki | loki | http://loki:3100 | Logs Explorer dashboard |

(Configured via `grafana/provisioning/datasources/datasources.yml`.)

## Troubleshooting

### Dashboard shows "No data"

1. Check Prometheus targets: https://grafana.himrate.com/explore → Prometheus → query `up` → all targets returning 1?
2. Check `prometheus.yml` scrape config matches actual accessory hostnames
3. Verify `prometheus_exporter` gem mounted в Rails app (`/metrics` endpoint)
4. For dormant dashboards (Cost Attribution): expected pre-launch

### SSO login fails

1. Check Google OIDC client config: redirect URI = `https://grafana.himrate.com/login/generic_oauth`
2. Email domain matches `himrate.com`?
3. Fallback к basic auth: GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD из 1Password

### Loki query times out

1. Reduce time range
2. Add more specific labels: `{container="himrate-web-staging-...", level="error"}`
3. Check Loki container logs: `docker logs himrate-loki --tail 50`

## Related

- `accessory_ops.md` — workflow operations
- `accessory_drift_detection.md` — auto-detection system
- `accessory_auto_remediation.md` — auto-trigger при drift
