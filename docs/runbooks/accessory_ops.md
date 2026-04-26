# Accessory Operations — CI Workflow Runbook

## Цель

Triggering accessory operations (reboot, boot, stop, restart) на staging/production через GitHub Actions workflow `accessory-ops.yml` без local PAT setup. Replaces manual `kamal accessory reboot` локальные команды (legacy flow остаётся valid emergency fallback per `kamal_local_deploy.md`).

## Когда использовать

- Drift detected (declared deploy.yml vs runtime image mismatch) → reboot accessory
- Scheduled maintenance window → restart accessory
- Emergency hot-fix → stop/boot accessory
- Image upgrade after deploy.yml change → reboot accessory с новым image

## Как trigger

### Через GitHub UI

1. Open https://github.com/himratesdev/himrate-platform/actions
2. Sidebar: select workflow `accessory-ops`
3. Right-side: click **Run workflow** dropdown
4. Select inputs:
   - **Deployment destination:** `staging` or `production`
   - **Accessory name:** `db`, `redis`, `grafana`, `prometheus`, `loki`, `promtail`, `alertmanager`, `prometheus-pushgateway`
   - **Kamal action:** `reboot`, `boot`, `stop`, `restart`
5. Click **Run workflow** button
6. Watch real-time log в job page

### Через CLI

```bash
gh workflow run accessory-ops.yml \
  -f destination=staging \
  -f accessory=db \
  -f action=reboot
```

### Production approval flow

При destination=production workflow остановится на approval gate:

1. PO получает GitHub notification (email + UI bell)
2. Open Actions → pending workflow → "Review pending deployments"
3. Select environment `production`
4. **Approve** → workflow continues
5. **Reject** → workflow exits cancelled

Approval timeout: 72 часа (job timeout-minutes 4320). После timeout — re-trigger required.

## Что workflow делает

1. Validate required secrets fail-fast (KAMAL_REGISTRY_PASSWORD, SSH_PRIVATE_KEY, POSTGRES_PASSWORD, GRAFANA_*, OIDC, Telegram secrets)
2. SSH setup к VPS host
3. Write `.kamal/secrets.<destination>` ephemeral file (cleaned up через `trap EXIT`)
4. Execute `kamal accessory <action> <name> -d <destination>`
5. **Health verification:** poll accessory health (3x retries, backoff 15s/30s/60s)
   - PostgreSQL: `pg_isready` via SSH
   - Redis: `redis-cli ping` via SSH
   - Grafana/Prometheus/Loki/Alertmanager: HTTP `curl /-/healthy` or `/api/health`
6. **State update:** write `accessory_state` DB row (current_image, previous_image, last_health_check_at)
7. **Audit annotation:** `::notice::Accessory ops: actor=<actor> destination=<dest> accessory=<acc> action=<act> result=<status> duration=<sec>s`
8. **Telegram notification:** push к Alertmanager `/api/v2/alerts` (production only). Alertmanager routes по severity (critical/ops/info channels).
9. **Auto-rollback (on health failure):** read `accessory_state.previous_image` → kamal accessory reboot с previous tag → second health check
   - Rollback success → audit `result=rolled_back`, Telegram alert
   - Rollback fail → audit `result=rollback_failed`, critical Telegram, manual intervention required

## Common operations

### Drift remediation

Drift detected (DV report or auto-detection alert):
```bash
gh workflow run accessory-ops.yml -f destination=production -f accessory=db -f action=reboot
```
PO approves → kamal pulls new image → health check → drift_event closed → metrics updated.

### Scheduled image upgrade

После update `config/deploy.yml` accessory image tag, merge к main:
```bash
gh workflow run accessory-ops.yml -f destination=staging -f accessory=grafana -f action=reboot
# Verify staging healthy via dashboard
gh workflow run accessory-ops.yml -f destination=production -f accessory=grafana -f action=reboot
# PO approves
```

### Emergency stop

```bash
gh workflow run accessory-ops.yml -f destination=production -f accessory=loki -f action=stop
# PO approves
```
Warning: stop = container removed. Boot back с `action=boot`.

## Safety model

- **Production approval:** required reviewer (himratesdev user) per ADR DEC-4
- **Concurrency:** workflow concurrency group `accessory-ops-<destination>-<accessory>` cancels older run на same pair (prevents race)
- **Typed enum inputs:** GitHub server-side validation (no free-form text injection)
- **Audit trail:** Actions log forever + Prometheus metrics + Alertmanager notification

## Health check methods (per accessory)

| Accessory | Health command | Method |
| --- | --- | --- |
| db (postgres-partman) | `pg_isready -h db -p 5432 -U himrate` | SSH execute |
| redis | `redis-cli -h redis ping` | SSH execute |
| grafana | `curl -sf http://grafana:3000/api/health` | HTTP |
| prometheus | `curl -sf http://prometheus:9090/-/healthy` | HTTP |
| prometheus-pushgateway | `curl -sf http://prometheus-pushgateway:9091/-/healthy` | HTTP |
| loki | `curl -sf http://loki:3100/ready` | HTTP |
| promtail | `curl -sf http://promtail:9080/ready` | HTTP |
| alertmanager | `curl -sf http://alertmanager:9093/-/healthy` | HTTP |

## Rollback procedure

Auto-rollback executes on health failure после kamal step success. Manual rollback if needed:

1. Trigger workflow с previous accessory image tag (revert deploy.yml first)
2. OR direct SSH к VPS:
   ```bash
   ssh root@194.135.85.159
   docker stop himrate-<accessory>
   docker run -d --name himrate-<accessory> <previous_image_tag>
   ```
3. Update `accessory_state` DB row to reflect manual rollback

## Troubleshooting

### Workflow fails at validate-secrets

Missing repo secret. Check Actions log для list missing names. Set via:
```bash
gh secret set <SECRET_NAME> --body "<value>" --repo himratesdev/himrate-platform
```

### Workflow fails at kamal accessory step

Check Actions log для kamal output. Common causes:
- **`denied: denied` (docker login)** — KAMAL_REGISTRY_PASSWORD expired, rotate per `kamal_local_deploy.md`
- **`manifest unknown`** — accessory image tag не существует в GHCR, verify deploy.yml
- **SSH timeout** — VPS unreachable, check Time4VPS panel

### Workflow auto-rollback executes

Health check после restart failed. Check logs:
- Grafana dashboard "Accessory Health Overview" — current state
- Logs Explorer dashboard — filter по container_name accessory
- Если rollback succeeded → drift_event remains open (deploy.yml still says new tag, rolled-back container running previous). Manual investigation: was new image broken? Если да → revert deploy.yml + new accessory_ops trigger.
- Если rollback failed → critical alert. Manual intervention: SSH к VPS, manually restart с known-good image.

## Related runbooks

- `kamal_local_deploy.md` — emergency local kamal CLI usage
- `accessory_drift_detection.md` — auto-detection sidekiq worker
- `grafana_dashboards.md` — dashboard reference
- `accessory_auto_remediation.md` — auto-trigger workflow при drift
- `pg_partman_recovery.md` — postgres volume recovery

<!-- BUG-010 PR1: trigger redeploy для accessory recreation после PR #115 user/entrypoint fixes -->
