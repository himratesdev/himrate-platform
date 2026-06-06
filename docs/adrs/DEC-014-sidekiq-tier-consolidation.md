# ADR DEC-014 — Sidekiq Tier-Based Consolidation (8 → 3 weighted roles)

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

VPS Time4VPS (3 vCPU / 8 GiB / 80 GiB) ran 8 distinct Sidekiq Kamal app roles by 2026-06-05:

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
- **Concurrency rationale:** c=10 threads = 10 PG connections. Signal compute (~3sec/job) at full
  utilization yields ~200 jobs/min steady-state. PG connection pool max=100 (default), this tier
  consumes 10% — within budget when summed with tier2 (5) + tier3 (5) + web (~10) + irc (1) + adhoc.

### Tier 2 — Async-important

`compute_tier2` — `bundle exec sidekiq -q post_stream,5 -q chat,5 -q pva_critical,5 -q pva_helix,5 -q pva_gql_anon,5 -q monitoring,5 -q default,5 -c 5`

- **Queues (equal weight 5):** post_stream, chat, pva_critical, pva_helix, pva_gql_anon, monitoring, default
- **Workers covered:** PostStreamWorker, MlFeatureExtractionWorker, StreamerReputationRefreshWorker,
  Trends::LatestTihRefreshWorker, Twitch::BigChannelChatterSweepWorker, StreamMonitorWorker,
  MonitoredLiveDetectorWorker, ChannelMetadataRefreshWorker, ChannelDiscoveryWorker,
  ChannelPruneWorker, ChatterProfileRefreshWorker, FollowerSnapshotWorker, BotListRefreshWorker,
  StaleStreamSweepWorker, SidekiqHealthMonitorWorker, CrossChannelDigestRefreshWorker, 5×
  PersonalAnalytics::* workers, all chat ingest workers, default-queue catch-all
- **Concurrency rationale:** c=5 threads. `monitoring` queue includes BSW which is high-volume
  (~4/min × 14sec = ~5760 jobs/day) — c=5 gives ~28k jobs/day capacity (~5× headroom).
- **`default` placement in tier 2:** Catch-all for jobs without explicit `queue:` attribute. Safer
  to land in async-important tier (faster pickup) vs batch tier — unknown criticality defaults
  to faster, reduces latency risk for unspecified worker classes.

### Tier 3 — Batch / deferred

`compute_tier3` — `bundle exec sidekiq -q notifications,2 -q accessory_ops,2 -q long_running,2 -c 5`

- **Queues (equal weight 2 — formality, only 3 queues):** notifications, accessory_ops, long_running
- **Workers covered:** EmailWorker, TelegramWorker, AccessoryDriftDetectorWorker,
  CostAttributionAggregationWorker, MlOps::TrainingWorker (long_running)
- **Concurrency rationale:** c=5 threads sufficient for low-volume periodic schedulers +
  occasional MlOps training run (long_running queue jobs cap via job-level timeout, not
  concurrency).

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
  pause expected (~30-90s container boot). Mitigated by Kamal accessory-config-change flag
  + DV verify step.
- **Concurrency tuning may need adjustment:** c=10/5/5 picked from current measurements
  (~33 Sidekiq threads total vs previous ~25); if PG connection pool saturates → tune down.
  Monitoring window 24h post-deploy required.
- **Tier 2 includes 7 queues weighted-fetched across 5 threads:** Effective fetch slice per
  queue ~14% × 5 threads = ~0.7 effective thread/queue. For BSW (`monitoring`, ~14sec/job)
  this is sufficient (5760 jobs/day capacity vs ~5760/day enqueue rate at saturation). For
  PVA queues which are bursty (cron-driven) may queue temporarily — acceptable per Tier 2
  async-important definition (job latency ~minutes OK).

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
- Kamal accessory roles NOT modified (only servers: section). No `kamal accessory reboot`
  needed; standard `kamal deploy` rolls server roles.
- STRICT live verify mandatory per [[feedback-live-verify-mandatory-violations-2026-06-03]].

## Subsequent PRs in lane

- **PR-B1b** (next, after B1a stable 24h): `accessories.db.cmd` revert shared_buffers 512 MB → 1024 MB
  (after RAM freed in B1a)
- **PR-B1c** (after B1b stable): Observability accessories OFF on staging (replaced by CO
  /dashboard/po-debug). Pending PO confirmation Q-T1-003.

Future PRs covered by separate ADRs (multi-host scale-out, storage tier separation, etc).
