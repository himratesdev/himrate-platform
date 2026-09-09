# frozen_string_literal: true

module Coordination
  # Hourly collector: one complete hour of chat → `coordination_events` (which channels each
  # co-firing account wrote in). Cheap by construction — ~160k rows per hour instead of the 7.6M
  # two-phase 24h scan that exhausted the query budget on the 16 GB box once channel arrays were kept.
  #
  # Self-healing: every run also fills any missing hour in the lookback (a restart, a paused flag, a
  # failed sweep), bounded so one run can never turn into a 24-hour scan. The insert is idempotent —
  # ReplacingMergeTree(hour, username) collapses a recollected hour.
  class EventsWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    FLAG = :coordination_engine
    LOOKBACK_HOURS = 26      # a touch over the day so a stalled night is repaired, not lost
    MAX_HOURS_PER_RUN = 6    # bound: one run stays a minutes-long job

    LOCK_KEY = "coordination:events:lock"
    LOCK_TTL = 10.minutes.to_i

    def perform
      return unless Flipper.enabled?(FLAG)
      # Release only what we took: an early return on a held lock must not free the run that owns it.
      return unless acquire_lock

      begin
        hours = missing_hours
        hours.each { |hour| Clickhouse::CoordinationQueries.collect_hour!(hour) }
        Rails.logger.info("Coordination::EventsWorker collected #{hours.size} hour(s)")
      rescue Clickhouse::Error => e
        Rails.logger.error("Coordination::EventsWorker: #{e.class}: #{e.message}")
        raise
      ensure
        release_lock
      end
    end

    private

    # Complete hours only: the current hour is still filling, and collecting it would write a
    # partial row that the Replacing engine would then keep until the next sweep overwrote it.
    def missing_hours
      # Compare as epoch seconds: the CH rows come back as TimeWithZone and the candidates are
      # plain UTC Times — same instant, different objects, so Set membership would never hit.
      done = Clickhouse::CoordinationQueries.collected_hours(hours: LOOKBACK_HOURS).map(&:to_i).to_set
      current = Time.current.utc.beginning_of_hour
      candidates = (1..LOOKBACK_HOURS).map { |back| current - back.hours }
      candidates.reject { |h| done.include?(h.to_i) }.sort.last(MAX_HOURS_PER_RUN)
    end

    def acquire_lock
      Sidekiq.redis { |r| r.set(LOCK_KEY, Time.current.to_i, nx: true, ex: LOCK_TTL) }
    end

    def release_lock
      Sidekiq.redis { |r| r.del(LOCK_KEY) }
    end
  end
end
