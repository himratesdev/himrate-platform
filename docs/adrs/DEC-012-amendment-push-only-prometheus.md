# ADR DEC-12 Amendment — Push-Only Prometheus Pattern (BUG-010 PR3)

**Status:** Active
**Original ADR:** DEC-12 (Notion: BUG-010 v3.0 Architecture Decisions)
**Amendment Date:** 2026-04-28
**Amendment Author:** Dev Agent (BUG-010 PR3)
**Authoritative Notion link:** Operator updates BUG-010 ADR v1.0 § DEC-12 with link к this file.

## Original DEC-12 (summary)

> Metrics architecture: **hybrid** approach. Workflow batch metrics (e.g.,
> `accessory_ops_action_duration_seconds`, `accessory_drift_active`) → push gateway
> (workflow runs once, push final state). Long-running services (`web`, `irc`, `job`
> roles) → `prometheus_exporter` gem providing `/metrics` endpoint scraped Prometheus
> directly. Direct scrape preferred для high-frequency in-process metrics (request
> duration histograms, Sidekiq queue depth, AR connection pool).

## Amendment

Metrics architecture: **push-only pattern.** All metrics — workflow batch AND service
runtime — push к `prometheus-pushgateway:9091` accessory. `prometheus_exporter` gem
NOT integrated. No `/metrics` endpoint в Rails app. Prometheus scrapes pushgateway
every 30s (existing PR1 config).

## Rationale (why amendment)

1. **`prometheus_exporter` 2.2.x bug compatibility issue.** Initial PR2 attempt к
   integrate gem revealed bugs:
   - `NoMethodError: undefined method 'app' for PrometheusExporter::Server::WebServer`
   - `FrozenError: can't modify frozen Array` on Rails engine `eager_load_paths`
   Bugs blocked CI test pipeline. Workaround attempts (downgrade gem, manual mount)
   either reverted bug fix или introduced new failures.

2. **Push gateway accommodates все use cases.** Pushgateway designed для batch jobs
   (accumulates state, scraped Prometheus), но также works fine для service runtime
   metrics при per-pair grouping labels (predictable label set, idempotent overwrite
   semantics matches gauge pattern).

3. **Single integration path simplifies operations.** Only one Prometheus surface
   (pushgateway) для drift detection, health checks, cost aggregation, action durations,
   rollback events. Operator не нужно понимать hybrid architecture: "everything pushes
   куда — Prometheus scrapes pushgateway."

4. **Build for years compatibility.** Pure Ruby `Net::HTTP::Post` к pushgateway has
   zero gem dependencies (only stdlib `net/http` + `uri`). Survives Rails major version
   bumps без concerns про gem compatibility.

## Trade-offs accepted

- **No request-scoped histograms** out of the box. If/when needed (e.g., API request
  duration p99 monitoring), revisit с alternative implementation: либо `prometheus_exporter`
  re-evaluation post-fix, либо Rails Middleware emitting к pushgateway per-request
  (acceptable cost для request volume <1k/sec).
- **Pushgateway accumulates groupings без TTL.** Mitigated через
  `accessory_ops:metrics:cleanup_stale_groupings` rake (deletes groupings для
  AccessoryStates без recent health_check >7 days).

## Revisit Trigger

When ≥1 of:
- `prometheus_exporter` gem 2.3+ released с fixed Rails engine eager_load_paths handling
- Ruby Prometheus client gem alternative emerges с stable Rails 8 support
- Project requires high-cardinality histograms (request durations, query latencies) что
  pushgateway inefficient для.

At that point: hybrid pattern — direct scrape для service runtime + pushgateway для
batch jobs (per original DEC-12). Migration path: introduce `/metrics` endpoint in
parallel, keep pushgateway emissions (additive change), shift dashboards к direct
scrape series gradually.

## Code references

- `config/initializers/prometheus.rb` — PrometheusMetrics push implementation (6
  observe_* methods + delete_grouping cleanup)
- `prometheus/prometheus.yml` — scrape_configs jobs (pushgateway + accessory self-metrics)
- `lib/tasks/accessory_ops.rake` — `metrics:cleanup_stale_groupings` cron consumer

## Cost / Risk

- Zero deploy cost: pushgateway accessory уже deployed PR1
- Risk on gem-fix path: when `prometheus_exporter` fixed, hybrid migration требует
  parallel emission window для dashboard validation. Mitigated через additive code
  change (PrometheusMetrics push remains, `/metrics` endpoint added independently).
