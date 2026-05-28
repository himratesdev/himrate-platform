# Flipper Tactical Pause-Override Runbook

> **BUG-251.21** — multi-hour disable of an `ALL_FLAGS` flag that survives Rails boot, container restart, and deploy. For one-deploy emergency disables, use `Flipper.disable(:flag)` directly (see §How it works → mechanism (a)).

## When to use

| Scenario | Mechanism | Lifetime |
|---|---|---|
| Multi-hour backfill / batch migration that competes with a worker for resources | **Pause-override** (this runbook) | Until explicit DEL by operator |
| Planned maintenance window > 30 minutes | **Pause-override** | Until explicit DEL by operator |
| Vent the steam — kill an active misbehaving feature, ship a fix in the next deploy | `Flipper.disable(:flag)` (no pause key) | Until next Rails boot (deploy / container restart) |
| Permanently disable a transitional/upcoming feature | Move flag to `HOOK_FLAGS` in `flipper.rb` | Code change required to re-enable |

Pause-override applies to flags in `FlipperDefaults::ALL_FLAGS` (those auto-enabled by the initializer). On flags in `FlipperDefaults::HOOK_FLAGS` the key has no effect at boot, since HOOK_FLAGS are not auto-enabled to begin with.

## How it works

`config/initializers/flipper.rb` runs on every Rails boot. The ALL_FLAGS loop now consults Redis BEFORE auto-enabling each flag:

```ruby
FlipperDefaults::ALL_FLAGS.each do |flag|
  Flipper.add(flag)
  if FlipperDefaults.pause_override_active?(flag, redis_instance)
    Flipper.disable(flag)
    Rails.logger.info("Flipper: pause-override active for #{flag} (reason: ...) — skipping auto-enable")
  else
    Flipper.enable(flag)
  end
end
```

The check reads Redis key `flipper:pause_override:<flag_name>` and:

- **Key exists** → flag is `Flipper.disable`d on boot, an INFO log entry records the pause reason.
- **Key missing** → flag is `Flipper.enable`d on boot (current behavior preserved).
- **Redis unreachable** → fails open (auto-enables), emits WARN. A flaky Redis at boot must not silently leave critical production flags off.

The two disable mechanisms — semantically distinct:

- **(a) `Flipper.disable(:flag)` without a pause key** — emergency kill switch. The current Redis state holds until the next deploy / container restart; on the next boot the initializer re-enables the flag. Correct for "vent the steam, ship the fix" scenarios.
- **(b) `flipper:pause_override:<flag>` key set** — multi-hour tactical pause. Survives every Rails boot (web/sidekiq/runner/rake/deploy) until the operator explicitly DELs the key.

## Operator commands

### Rake tasks (preferred — argument validation + audit-friendly output)

```bash
# List active pauses
bin/rails flipper:pause:list

# Set a pause-override (FLAG + REASON required; reason becomes the audit trail)
#   ⚠ Rake parses bracket args by comma → reason MUST NOT contain commas. If the reason
#     needs commas, use redis-cli directly (see "redis-cli" subsection below).
bin/rails 'flipper:pause:set[signal_compute,TASK-251.14 backfill]'

# Clear one pause-override
bin/rails 'flipper:pause:clear[signal_compute]'

# Clear ALL pause-overrides (use with care)
bin/rails flipper:pause:clear_all

# Show all known ALL_FLAGS + HOOK_FLAGS (for valid targets)
bin/rails flipper:pause:flags
```

### redis-cli (when Rails is unavailable or for one-off ops)

```bash
# Set — use this form when the reason must contain commas (the rake task above truncates).
docker exec himrate-redis redis-cli -n 1 SET flipper:pause_override:signal_compute "TASK-251.14 backfill"

# Inspect
docker exec himrate-redis redis-cli -n 1 GET flipper:pause_override:signal_compute
docker exec himrate-redis redis-cli -n 1 --scan --pattern 'flipper:pause_override:*'

# Clear
docker exec himrate-redis redis-cli -n 1 DEL flipper:pause_override:signal_compute
```

> **Important: Redis key format.** Flipper itself stores per-flag state as a Redis hash named after the bare flag (e.g. `signal_compute` with field `boolean`). The pause-override mechanism uses a separate namespace `flipper:pause_override:*` — distinct keys, distinct semantics. Do not mix them.
>
> **CR-iter1 #5:** The `redis-cli HDEL <flag> boolean` shown in §1 below is a Flipper-internal storage detail (verified against `flipper 1.4.x` as bundled in this repo). If we bump the Flipper major version and the gem renames the gate field, prefer the gem-agnostic `bin/rails runner 'Flipper.disable(:<flag>)'` form instead — same effect on the running workers without depending on the storage layout.

## Operational scenarios

### 1. Multi-hour backfill — disable competing worker for the duration

Goal: free Postgres I/O for the backfill by stopping `SignalComputeWorker` from sweeping the same table.

```bash
# 1) Set the pause-override (survives across rake spawns / runner probes / cron / deploys)
bin/rails 'flipper:pause:set[signal_compute,TASK-251.14 backfill]'

# 2) Take effect on the currently running Sidekiq workers (they re-read Flipper state per job).
#    Prefer the gem-agnostic Rails form — same effect, no dependency on the Flipper storage layout
#    (the `redis-cli HDEL <flag> boolean` form works for `flipper 1.4.x` but rots on major bumps).
docker exec <web-container> ./bin/rails runner 'Flipper.disable(:signal_compute)'

# 3) Verify in a fresh Rails session — boot would normally re-enable, but the pause holds.
docker exec <web-container> ./bin/rails runner 'puts Flipper.enabled?(:signal_compute)'
# Expected: false

# 4) Start the backfill (Rails boot triggered by the rake task respects the pause)
docker exec -d <web-container> bash -c "nohup ./bin/rails 'clickhouse:backfill_chat[...]' > /tmp/backfill.log 2>&1"

# 5) After backfill completes (status=done), restore auto-enable:
bin/rails 'flipper:pause:clear[signal_compute]'

# 6) Bring the worker back on the running containers (without waiting for the next boot):
docker exec <web-container> ./bin/rails runner 'Flipper.enable(:signal_compute)'
```

### 2. Emergency kill — disable for one deploy cycle

Use the existing `Flipper.disable` path. Do **not** set a pause-override.

```bash
docker exec <web-container> ./bin/rails runner 'Flipper.disable(:bot_scoring)'
```

The next deploy re-enables. Ship the fix; do not leave a dangling pause key.

### 3. Discover an accidental pause

The pause-override is sticky — it survives boots. If a flag is mysteriously OFF in production:

```bash
bin/rails flipper:pause:list
# OR
docker exec himrate-redis redis-cli -n 1 --scan --pattern 'flipper:pause_override:*'
```

The list shows the reason string set at SET time, so the operator who set it left an audit trail.

### 4. Disaster: Redis flushed / replaced

Pause-overrides live in Redis. A `FLUSHDB` / fresh Redis instance wipes them. On the next Rails boot, all ALL_FLAGS auto-enable — the system returns to baseline. This is intentional: pause-override is an operational tool, not a configuration source of truth.

If a long-running pause must survive a Redis replacement, set it again after the new Redis is up.

## Monitoring + Alerts

- **Audit log:** every boot that respects a pause-override emits an INFO line with the pause reason. Grep with `journalctl` / `kamal logs` / Grafana Loki:
  ```
  Flipper: pause-override active for signal_compute (reason: "...") — skipping auto-enable
  ```
- **Stale pause detection:** if a pause has been active for > 24h without a parent task in flight, treat it as suspect. Add it to the weekly ops review.

## Adding new ALL_FLAGS

When adding a new flag to `FlipperDefaults::ALL_FLAGS`, no extra code is needed — the pause-override mechanism applies uniformly to every flag in the list. The new flag automatically picks up the same pause/resume operator UX.

## Related

- Memory: `feedback_initializer_flag_reenable_cycle` — incident pattern and design rationale
- Memory: `feedback_no_throwaway_go_to_final_architecture` — why pause-override over HOOK_FLAGS migration
- Parent: TASK-251 Combat Program
- Incident BUG-251.21 (this fix)
