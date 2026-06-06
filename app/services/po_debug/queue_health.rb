# frozen_string_literal: true

require "sidekiq/api"

module PoDebug
  # Block 4 — Sidekiq queue depths + throughput.
  #
  # Queue list = `Sidekiq::Queue.all` at runtime (canonical: surfaces every queue
  # currently registered in Redis, in sync with `config/sidekiq.yml :queues`
  # without manual mirroring). A hardcoded whitelist would silently hide new
  # queues (e.g. chat / pva_critical / pva_helix / post_stream) — defeating the
  # dashboard's purpose during T1's consolidation work.
  #
  # Throughput = jobs/sec rolling window via Sidekiq::Stats.processed delta,
  # baseline persisted in Redis between Aggregator runs (CACHE_TTL=5s).
  class QueueHealth
    THROUGHPUT_KEY = "po_debug:queue_health:throughput_baseline"

    def self.call
      new.call
    end

    def call
      stats = Sidekiq::Stats.new

      processed_total = stats.processed
      failed_total = stats.failed
      baseline = previous_baseline
      now = Time.current.to_i

      throughput = compute_throughput(processed_total, baseline, now)
      persist_baseline(processed_total, now)

      {
        global: {
          processed_total: processed_total,
          failed_total: failed_total,
          enqueued: stats.enqueued,
          scheduled: stats.scheduled_size,
          retry_size: stats.retry_size,
          dead_size: stats.dead_size,
          throughput_jps: throughput,
          processes: Sidekiq::ProcessSet.new.size,
          workers_busy: Sidekiq::Workers.new.size
        },
        queues: queue_rows
      }
    end

    private

    def queue_rows
      # Sort by depth descending so the PO sees worst queues at the top —
      # operational priority during incident triage.
      Sidekiq::Queue.all.map do |q|
        oldest = q.first&.enqueued_at
        oldest_age = oldest ? (Time.current.to_f - oldest.to_f).round(1) : nil
        {
          name: q.name,
          depth: q.size,
          latency_sec: q.latency.round(2),
          oldest_job_age_sec: oldest_age
        }
      end.sort_by { |r| -r[:depth] }
    end

    def previous_baseline
      raw = redis { |r| r.get(THROUGHPUT_KEY) }
      return nil unless raw

      JSON.parse(raw, symbolize_names: true)
    rescue StandardError
      nil
    end

    def persist_baseline(processed, ts)
      payload = JSON.dump(processed: processed, ts: ts)
      redis { |r| r.set(THROUGHPUT_KEY, payload, ex: 120) }
    end

    def compute_throughput(processed_now, baseline, now)
      return nil unless baseline.is_a?(Hash) && baseline[:processed] && baseline[:ts]

      delta_jobs = processed_now - baseline[:processed]
      delta_sec = now - baseline[:ts]
      return nil if delta_sec <= 0 || delta_jobs.negative?

      (delta_jobs.to_f / delta_sec).round(2)
    end

    def redis(&block)
      Sidekiq.redis(&block)
    end
  end
end
