# ADR DEC-014 — Sidekiq Tier-Based Consolidation (6 consolidatable Sidekiq roles → 3 tier-weighted)

**Status:** Accepted 2026-06-06 (PO directive)
**Cross-ref:**
- EPIC SCALE ARCHITECTURE §2 Topology Target (`_tasks/EPIC-SCALE-ARCHITECTURE/CONTEXT.md`)
- Phase 7 R REVISED plan Step 5 (`_tasks/Phase-7-R-vps-upgrade/REVISED-PRE-MIGRATION-OPTIMIZATION-PLAN.md`)
- AUDIT 2026-06-05 nix findings (`_tasks/AUDIT-2026-06-05-NIX/findings.md`)
- T1-SPAWN-PROMPT (`_tasks/TASK-PO-DEBUG-DASHBOARD/T1-SPAWN-PROMPT.md`)
- [[feedback-build-for-scale-no-iterative-band-aids]]
- [[feedback-no-throwaway-go-to-final-architecture]]
- [[feedback-vps-capacity-saturation-signal]]
- ADR DEC-012 / DEC-013 (predecessors — observability)
- Predecessors in commit history: BUG-251.40-F (PR #240), PR #257 (signal_compute_worker),
  PR #270 (signals_worker), PR #274 (monitoring_worker), PR #282 (Phase 7 S), PR #283 (Phase 7 T)

---

## Context

VPS Time4VPS (3 vCPU / 8 GiB / 80 GiB) ran 9 total Kamal app roles by 2026-06-05 (web + irc + 7 Sidekiq-loaded roles below; 6 of which are consolidatable, whisper_worker preserved as GPU-isolated):

| Role | Queue scope | Concurrency | Added by |
| --- | --- | --- | --- |
| `job` | weighted-fetch all 14 queues from `sidekiq.yml :queues` | c=5 | original (catch-all) |
| `whisper_worker` | `-q whisper_transcripts` strict | c=1 | TASK-110 v1.2 (GPU isolation) |
| `stream_worker` | `-q stream_lifecycle` strict | c=3 | BUG-251.40-F PR #240, 2026-06-01 |
| `signal_compute_worker` | `-q signal_compute` strict | c=5 | PR #257, 2026-06-02 |
| `signals_worker` | `-q signals` strict | c=5 | PR #270, 2026-06-03 (Phase 7 O) |
| `monitoring_worker` | `-q monitoring` strict | c=4 | PR #274, 2026-06-03 + PR #283 c=2→4 |
| `bot_scoring_worker` | `-q bot_scoring` strict | c=3 | PR #283, 2026-06-05 (Phase 7 T) |

Each dedicated role was added in response to a different queue-starvation incident:
SignalComputeWorker starving `:signals` → split `:signal_compute` → starving `:bot_scoring` (Phase 7 S
attempted strict-precedence piggy-back, failed) → split `:bot_scoring` → etc. **Each addition was
band-aid in response to last starvation, не architectural design.**

Each Sidekiq Kamal role is a full Rails boot. Measured 2026-06-06 03:13Z on `a886193`:

| Role | RSS | CPU% |
| --- | --- | --- |
| job | 526 MiB | 4.15% |
| stream_worker | 71 MiB | 1.91% |
| signal_compute_worker | 259 MiB | 2.58% |
| bot_scoring_worker | 380 MiB | 2.48% |
| signals_worker | 144 MiB | 1.07% |
| monitoring_worker | 257 MiB | 33.13% ← saturated |
| **Subtotal (6 consolidatable)** | **1637 MiB ≈ 1.6 GiB** | |
| whisper_worker (NOT consolidatable, GPU-bound) | 41 MiB | 0.02% |
| irc, web (NOT Sidekiq) | 171 MiB | — |

In parallel: load avg 27.25 on 3 cores · swap 1.3 GiB residual · disk %util 91-93% · iowait 54-86%.

Operational impact compounding:
- **VPS deploy fails reproducibly under load 25-35** ([[feedback-vps-capacity-saturation-signal]]):
  PR #275, #276 (and the original PR #214/#215 ECONNRESET incident) all failed health-check at
  240s deploy_timeout. Adding the 8th role had pushed sequential Kamal deploy sequence to
  approach GH Actions 45m job timeout.
- **Disk I/O bottleneck** ([[feedback-disk-io-root-cause-2026-06-05]]): 6× Rails boot = 6×
  PG connection pool + 6× Redis connection pool + 6× autoload disk reads at boot. Coupled
  with ClickHouse compaction (42.5% CPU 1 vCPU full) + PG SELECTs in D-state, disk is
  saturated.
- **Phase 1 launch readiness:** Scaling to 1000 channels (4× current) under this topology
  would require either (a) larger box (band-aid per [[feedback-build-for-scale]]) or (b)
  more dedicated roles (доработка-доработки-доработки per same).

---

## Decision

Replace the 6 dedicated Sidekiq Kamal roles (job + stream_worker + signal_compute_worker +
bot_scoring_worker + signals_worker + monitoring_worker) with **3 tier-based weighted-fetch
roles** matching EPIC SCALE ARCHITECTURE §2 Topology Target:

### Tier 1 — Realtime-critical

`compute_tier1` — `bundle exec sidekiq -q signal_compute,10 -q bot_scoring,10 -q stream_lifecycle,10 -q signals,10 -c 10`

- **Queues (equal weight 10 — round-robin fairness):** signal_compute, bot_scoring, stream_lifecycle, signals
- **Workers covered:** SignalComputeWorker, BotScoringWorker, LiveBotScoringWorker, StreamOnlineWorker,
  StreamOfflineWorker, Trends::AnomalyAttributionWorker, Trends::AggregationWorker, RaidWorker,
  ChannelUpdateWorker
- **Concurrency rationale (CR M1 fix):** c=10 Sidekiq threads require **per-process ActiveRecord pool ≥ 10**.
  Two layers of pool sizing here:
  1. **Per-process AR pool** (`config/database.yml` `pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>`)
     — driven by `RAILS_MAX_THREADS` env, set to **10** for compute_tier1 in `deploy.yml` `env: clear:`.
     Without this fix, the prior `max_connections:` key in database.yml was silently ignored (not a
     recognized AR key) → effective pool defaulted to 5 → c=10 would block threads 6–10 on connection
     checkout (`ActiveRecord::ConnectionTimeoutError` after 5s). PR-B1a fixes both the AR key
     (`max_connections:` → `pool:`) and adds per-role `RAILS_MAX_THREADS` overrides.
  2. **PostgreSQL server `max_connections`** (server-level, default 100) — verified sufficient:
     tier1(10) + tier2(5) + tier3(5) + web(3) + whisper(1) = 24 max client slots, with ample
     headroom for live console / ad-hoc psql.

### Tier 2 — Async-important

`compute_tier2` — `bundle exec sidekiq -q post_stream,5 -q chat,5 -q pva_critical,5 -q pva_helix,5 -q pva_gql_anon,5 -q monitoring,10 -q default,5 -c 5`

- **Queues:** post_stream (5), chat (5), pva_critical (5), pva_helix (5), pva_gql_anon (5),
  **monitoring (10 — bumped per CR S2 fix)**, default (5).
- **Workers covered:** PostStreamWorker, MlFeatureExtractionWorker, StreamerReputationRefreshWorker,
  Trends::LatestTihRefreshWorker, Twitch::BigChannelChatterSweepWorker, StreamMonitorWorker,
  MonitoredLiveDetectorWorker, ChannelMetadataRefreshWorker, ChannelDiscoveryWorker,
  ChannelPruneWorker, ChatterProfileRefreshWorker, FollowerSnapshotWorker, BotListRefreshWorker,
  StaleStreamSweepWorker, SidekiqHealthMonitorWorker, CrossChannelDigestRefreshWorker, 5×
  PersonalAnalytics::* workers, all chat ingest workers, default-queue catch-all.
- **Concurrency rationale (CR M1 fix):** c=5 Sidekiq threads, `RAILS_MAX_THREADS=5` in deploy.yml
  per-role env → AR pool = 5 (matches concurrency).
- **Honest monitoring drain capacity (CR S2 fix):** with weight 10 (vs 5 for other tier2 queues),
  monitoring gets `10 / (10 + 5×6) = 25%` of fetch slots × c=5 = **~1.25 effective thread**.
  BSW BigChannelChatterSweep avg job ~14sec → 1.25 × (1/14) = 0.089 j/s = **~7700 jobs/day capacity**.
  Observed enqueue rate (2026-06-03 baseline) was ~5760/day → ~33% headroom. **This is LESS than the
  prior dedicated `monitoring_worker -c 4` (theoretical ~34k/day) — a real reduction in monitoring
  drain capacity is the cost of consolidation.** Backlog will accumulate if (a) BSW jobs spike past
  8s avg or (b) PVA queues drain faster than expected (taking fetch slots from monitoring within
  weighted tier2). Mitigation plan: monitor `:monitoring` queue size 24h post-deploy; if backlog
  grows sustained → bump tier2 `c=5 → c=7` (will require RAILS_MAX_THREADS=7 update).
- **`default` placement in tier 2:** Catch-all for jobs without explicit `queue:` attribute. Safer
  to land in async-important tier (faster pickup) vs batch tier — unknown criticality defaults
  to faster, reduces latency risk for unspecified worker classes.

### Tier 3 — Batch / deferred

`compute_tier3` — `bundle exec sidekiq -q notifications,2 -q accessory_ops,2 -q long_running,2 -c 5`

- **Queues (equal weight 2 — formality, only 3 queues):** notifications, accessory_ops, long_running
- **Workers covered:** EmailWorker, TelegramWorker, AccessoryDriftDetectorWorker,
  CostAttributionAggregationWorker, MlOps::TrainingWorker (long_running)
- **Concurrency rationale (CR M1 fix):** c=5 threads, `RAILS_MAX_THREADS=5` → AR pool = 5.
  Sufficient for low-volume periodic schedulers + occasional MlOps training run (long_running
  queue jobs cap via job-level timeout, not concurrency).

### Preserved roles

- `whisper_worker` — unchanged. GPU-bound by nature (`--cpus 1.5` cap, single inference at a
  time). Not consolidated into tier1/2/3.
- `irc` — unchanged. Stateful connection-pinned process for Twitch IRC monitor. Not Sidekiq.
- `web` — unchanged. Puma not Sidekiq.

---

## Rationale (why 3-tier, NOT single, NOT 2-split)

Per T1-SPAWN-PROMPT Architect-style decision delegation. Three options considered:

**Option (a) — single `general_worker c=8 strict-priority`:**

Strict-priority ordering `-q signals -q signal_compute -q monitoring -q bot_scoring ...` with
c=8. RAM cheapest (1 boot ≈ 350-400 MiB save ~1.2 GiB). **Rejected:** band-aid under scale.
Tier 3 batch (cleanup_worker daily VACUUM / Trends::NightlyAggregationWorker / MlOps trainer)
running in same process as Tier 1 realtime starves under Phase 1 scale (1000 channels). PG
connection pool contention spikes. Strict-priority blocks Tier 3 forever if Tier 1 ever
saturates (which is the reason this consolidation exists).

**Option (b) — 2-role split `general_worker + compute_worker`:**

Compromise. RAM intermediate (2 boots ≈ 700-800 MiB save ~900 MiB). **Rejected:** doesn't
align with EPIC §2 Tier 1/2/3 target. On Phase 2 scale (5k channels) Tier 3 batch needs
isolation from Tier 2 async-important — would require third split = доработка-доработки per
[[feedback-build-for-scale-no-iterative-band-aids]].

**Option (c) — 3-tier weighted (selected):**

RAM cost (3 boots ≈ 1050-1350 MiB save ~300-600 MiB). **Selected:**
- Matches EPIC SCALE ARCHITECTURE §2 Topology Target exactly (Tier 1 c=10×N replicas, Tier 2
  c=5×N replicas, Tier 3 c=5×N replicas).
- Multi-host ready via Kamal `hosts: [host1, host2, ...]` — scales horizontally without code
  change per [[feedback-no-throwaway-go-to-final-architecture]] (final architecture immediately).
- Tier 3 batch isolation prevents batch jobs blocking realtime under load.
- Weighted-fetch within tier (equal weight) gives round-robin fairness across queues of same
  criticality.

---

## Consequences

### Positive

- **Memory:** ~300-600 MiB freed (3 Rails boot duplicates removed). Conservative estimate.
- **Disk I/O:** Fewer Rails processes = fewer parallel PG connection pool boots + fewer Redis
  connections + less autoload disk reads at boot. Reduces sustained disk activity which is
  current bottleneck per [[feedback-disk-io-root-cause-2026-06-05]].
- **Scale readiness:** Configuration matches end-state Topology Target. Phase 1 launch (1000
  channels / 5k users) deployable via `hosts: [box1, box2]` config edit, NO code change.
- **Deploy success rate:** Fewer roles to sequentially deploy = shorter total deploy time =
  less chance of GH Actions timeout under load saturation.
- **Operational clarity:** Tier hierarchy maps directly to criticality, not historical
  starvation incidents. Future workers added by setting `queue:` to appropriate criticality
  bucket — no need to add new Kamal role per new starvation event.

### Negative

- **Initial deploy risk:** Full Kamal role config change cannot be rolling — all 6 old role
  containers must be removed and 3 new tier role containers started. Brief Sidekiq processing
  pause expected (~30-90s container boot). Mitigated by DV verify step.
- **Loss of cross-role fallback redundancy (CR S1 fix):** Pre-PR-B1a architecture had an
  implicit N+1 safety net — the `job` catch-all role consumed every queue at low weight,
  meaning a crashed dedicated role (`signal_compute_worker`, `bot_scoring_worker`, etc.) still
  saw its queue drain (slowly) via `job`. The historical sidekiq.yml per-queue comments
  explicitly relied on this. After this PR there is **no `job` catch-all**: each queue has a
  **single role consumer**, so if `compute_tier1` crashes, signal_compute + bot_scoring +
  stream_lifecycle + signals queues all stall until the container restarts. Same for tier2/3.
  - **Why accept:** Multi-host scale-out (Kamal `hosts: [box1, box2]` per EPIC §3 Phase 1)
    restores N+1 naturally — second box brings second compute_tier1 process per role. Until
    Phase 1 launch (single-box staging), manual `kamal app restart -r compute_tierN -d staging`
    is the recovery path. Acceptable tradeoff given that the band-aid `job` fallback drained
    at <0.1 thread/queue under saturation anyway (per sidekiq.yml historical comments — "would
    take 300+ days to drain at fractional fetch share").
- **Monitoring drain capacity regression (CR S2 fix):** See Tier 2 rationale above. Honest
  capacity ~7700/day vs prior dedicated ~34k/day theoretical. Acceptable per current enqueue
  rate ~5760/day. Re-tune via `c=5→7` if backlog grows >24h sustained.
- **Concurrency tuning may need adjustment:** c=10/5/5 picked from current measurements
  (~20 Sidekiq threads total vs previous ~25 across 6 dedicated). RAILS_MAX_THREADS env per
  role properly sizes AR pool (CR M1 fix). PG server max_connections=100 has headroom for
  24 client slots used. If PG pool saturates → tune individual tier RAILS_MAX_THREADS down.
  Monitoring window 24h post-deploy required.
- **Stale sidekiq.yml comments fixed (CR N2):** Per-queue historical comments about "default
  job role fallback" updated to reflect new tier mapping; old reference to N+1 redundancy
  marked as removed.

### Risks + mitigations

| Risk | Mitigation |
| --- | --- |
| Tier 1 c=10 saturates PG connection pool when summed with web + tier2 + tier3 + irc + adhoc | Monitor pg_stat_activity post-deploy. If >80 active → tune c=10 → c=8. |
| Tier 2 BSW BigChannelChatterSweep (14sec/job × c=5 = 70 max concurrent outbound) exceeds Twitch GQL ~800 req/min soft cap | Per AUDIT 2026-06-05 finding #5, soft cap not exceeded at current c=4 monitoring_worker. New c=5 within budget. Monitor 429 response rate post-deploy. |
| Deploy fails health check under load 27 (current) per [[feedback-vps-capacity-saturation-signal]] | (a) Pre-deploy verify `kamal lock status -d staging`; (b) if fails, release lock per [[feedback-kamal-lock-leak-on-econnreset]]; (c) if fails 2× — drain `:monitoring` queue first to reduce CPU contention then retry. |
| Some worker missed in tier mapping → queue not consumed | Verified all 14 queues from `config/sidekiq.yml :queues` are covered: tier1 (signal_compute, bot_scoring, stream_lifecycle, signals) + tier2 (post_stream, chat, pva_critical, pva_helix, pva_gql_anon, monitoring, default) + tier3 (notifications, accessory_ops, long_running) = 14 ✓. whisper_transcripts NOT in `sidekiq.yml :queues` — covered by `whisper_worker` role per existing config. |

### Rollback plan

If deploy fails or post-deploy STRICT live verify fails:

1. `git revert <merge_sha>` → PR through autopilot
2. Auto-merge revert → triggers redeploy with old 6 dedicated roles
3. Verify live streamer TIH/BSW/MLFE recency restored after rollback
4. Risk window: 5-15 min on revert PR + redeploy

---

## Implementation

PR-B1a diff:
- `config/deploy.yml` — remove 6 dedicated server roles (job, stream_worker, signal_compute_worker, bot_scoring_worker, signals_worker, monitoring_worker), add 3 tier roles (compute_tier1, compute_tier2, compute_tier3)
- `docs/adrs/DEC-014-sidekiq-tier-consolidation.md` — this file
- `config/sidekiq.yml` — unchanged (queue definitions remain for any fallback paths +
  serves as :queues default for whisper_worker which uses explicit `-q` flag)
- `ai-dev-team/PARALLEL_BOARD.md` — T1 row update for autopilot tracking

Post-merge:
- Kamal accessory roles NOT modified (only `servers:` section). No `kamal accessory reboot`
  needed; standard `kamal deploy -d staging` rolls the new server roles.
- **CR S3 fix — explicit stop of removed roles required:** `kamal deploy` deploys roles
  **present** in `config/deploy.yml`; it does NOT stop or remove containers for roles
  deleted from config. The 6 old role containers (job / stream_worker /
  signal_compute_worker / bot_scoring_worker / signals_worker / monitoring_worker) will
  keep running as orphans unless explicitly stopped, both wasting the RAM this PR aims
  to free AND double-consuming queues (race conditions). After deploy succeeds, run:
  ```
  for role in job stream_worker signal_compute_worker bot_scoring_worker signals_worker monitoring_worker; do
    kamal app stop -r "$role" -d staging || true
    kamal app remove -r "$role" -d staging || true
  done
  ```
  These commands are documented in the deploy runbook step (DV verifies orphan removal).
  Verification: `docker ps --format '{{.Names}}' | grep himrate-` should show ONLY web,
  compute_tier1, compute_tier2, compute_tier3, whisper_worker, irc + accessories.
- STRICT live verify mandatory per [[feedback-live-verify-mandatory-violations-2026-06-03]].

## Subsequent PRs in lane

- **PR-B1b** (next, after B1a stable 24h): `accessories.db.cmd` revert shared_buffers 512 MB → 1024 MB
  (after RAM freed in B1a)
- **PR-B1c** (after B1b stable): Observability accessories OFF on staging (replaced by CO
  /dashboard/po-debug). Pending PO confirmation Q-T1-003.

Future PRs covered by separate ADRs (multi-host scale-out, storage tier separation, etc).
