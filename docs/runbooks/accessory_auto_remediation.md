# Accessory Auto-Remediation Runbook

## Цель

Auto-trigger `accessory-ops.yml` workflow при drift detection. **Staging:** full auto (no approval). **Production:** auto-trigger eliminates manual click, но approval gate сохранён (BR-001 NOT violated). Cool-down 24h prevents loops. Max 3 attempts per 72h.

## Architecture

- **Worker integration:** `AccessoryDriftDetectorWorker` → при detection event opened, IF Flipper flag `accessory_auto_remediation` ON → call `AutoRemediation::TriggerService`
- **Service:** `AutoRemediation::TriggerService.call(destination:, accessory:, drift_event_id:)`
- **GitHub API:** `POST /repos/.../actions/workflows/accessory-ops.yml/dispatches` с inputs body
- **Audit log:** `auto_remediation_log` DB table (id, destination, accessory, drift_event_id, triggered_at, result, attempt_number, disabled_at?, disable_reason?)
- **Cool-down:** SELECT FROM auto_remediation_log WHERE (destination, accessory) AND triggered_at > NOW()-24h
- **Max attempts:** SELECT COUNT WHERE (destination, accessory) AND triggered_at > NOW()-72h. IF >=3 → auto-disable Flipper flag scoped к accessory + critical alert (per ADR DEC-16)

## Flag activation

Default OFF. Activate after PR1+PR2 deployed AND validated:

```bash
# Via Flipper UI
open https://staging.himrate.com/admin/flipper
# Enable "accessory_auto_remediation"

# OR via Rails console
docker exec -it himrate-web bundle exec rails runner "Flipper.enable(:accessory_auto_remediation)"
```

## Lifecycle per detection cycle

1. Worker detects drift → opens `accessory_drift_events` event
2. IF flag ON:
   a. Check cool-down (last auto-trigger > 24h ago?) — if not, skip
   b. Check max attempts (count >= 3 last 72h?) — if yes, skip + critical alert + auto-disable flag для этого (destination, accessory)
   c. Trigger workflow: `POST /actions/workflows/accessory-ops.yml/dispatches`
   d. Workflow inputs: `destination=<dest>`, `accessory=<acc>`, `action=reboot`, `triggered_by=auto_remediation`, `auto_remediation_event_id=<uuid>`
3. Workflow runs:
   - Staging: kamal restart → health check → state update → audit annotation `triggered_by=auto_remediation`
   - Production: kamal restart waits approval → PO approves → continues per staging path
4. INSERT auto_remediation_log row с result (triggered/skip_cooldown/skip_max_attempts/api_error)

## Cool-down behavior

24h sliding window. Если drift recurs within 24h после auto-remediation — worker detects, opens event, BUT skips auto-trigger (logs `skip_cooldown` в auto_remediation_log). Manual trigger via `accessory_ops.md` runbook still works.

После 24h ok auto-trigger again. Если drift truly persistent (3 fails в 72h) → auto-disable.

## Auto-disable behavior

Triggered conditions: 3 failed auto-remediations within 72h sliding window для одной (destination, accessory) pair.

Effect:
- INSERT auto_remediation_log с `disabled_at=NOW()`, `disable_reason='max_attempts_exhausted'`
- Critical alert: "🔴 ROLLBACK FAILED loop: production/db disabled auto-remediation после 3 failed attempts. Manual investigation required."
- Worker future detections will skip auto-trigger для этой pair (until manual re-enable)

### Manual re-enable

```bash
docker exec -it himrate-web bundle exec rails runner "
AutoRemediationLog.where(
  destination: 'production',
  accessory: 'db',
  disabled_at: 72.hours.ago..
).update_all(disabled_at: nil, disable_reason: nil)
"
```

## Production approval flow (auto-triggered)

Same as manual trigger (per `accessory_ops.md`):

1. Auto-trigger creates workflow run
2. PO получает GitHub notification
3. Open Actions → workflow run → Review pending deployments
4. Approve / Reject

**Difference from manual:** audit annotation marks `triggered_by=auto_remediation` (vs `manual`). PO sees context which event triggered it (drift_event_id passed in inputs).

## Edge cases

### GitHub API rate-limit на trigger

`AutoRemediation::TriggerService` uses `AUTO_TRIGGER_GH_PAT` (fine-grained PAT, scope: actions:write на himrate-platform). Sidekiq retry с backoff handles transient errors. Note: `GITHUB_` prefix зарезервирован GitHub Actions (HTTP 422 при попытке create secret).

### Sidekiq worker down при drift

`AccessoryDriftDetectorWorker` won't run → no detection → no auto-trigger. `SidekiqHealthMonitorWorker` (separate, ADR DEC-5) alerts critical если worker heartbeat stale.

### Multiple drift events same accessory

One open event at time (partial index unique constraint). Cool-down скopen track latest auto-trigger.

### Flag enabled mid-cycle

Active drift events не auto-trigger retroactively. Worker checks flag on next detection cycle (hourly).

## Monitoring

- **Drift Trend dashboard:** `accessory_drift_active` gauge, MTTR with auto-remediation events labeled
- **Operations Frequency dashboard:** count operations с `triggered_by=auto_remediation` label
- **Audit query:**
  ```sql
  SELECT destination, accessory, COUNT(*) as triggers, MAX(triggered_at) as last
  FROM auto_remediation_log
  WHERE triggered_at > NOW() - INTERVAL '7 days'
  GROUP BY destination, accessory;
  ```

## Disable globally

```bash
# Disable Flipper flag
docker exec -it himrate-web bundle exec rails runner "Flipper.disable(:accessory_auto_remediation)"
```

Worker continues drift detection (still opens events, sends alerts) but no auto-trigger workflow. Manual trigger via UI still works.

## Related

- `accessory_ops.md` — manual workflow trigger
- `accessory_drift_detection.md` — detection worker
- `grafana_dashboards.md` — monitoring
