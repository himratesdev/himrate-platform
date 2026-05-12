# frozen_string_literal: true

# TASK-086 FR-032 (ADR-086 §4.2): refresh the latest_tih_per_stream materialized
# view. Enqueued from PostStreamWorker via perform_in(2.minutes, stream_id) after
# the post-stream final compute — same enqueue pattern as
# Trends::QualifyingPercentileSnapshotWorker.
#
# Dedup: a SESSION-level advisory lock (pg_try_advisory_lock + explicit unlock).
# It must be session-level (not pg_try_advisory_xact_lock) because
# `REFRESH MATERIALIZED VIEW CONCURRENTLY` cannot run inside a transaction, and an
# xact-lock requires one. If the lock is held (another refresh in flight, or several
# streams ended in the same window), return — the next stream's enqueue re-triggers,
# so no refresh is lost. This also gives a debounce effect at prime time (many ended
# streams collapse into one refresh).
#
# REFRESH ... CONCURRENTLY requires a UNIQUE index on the MV
# (idx_latest_tih_per_stream_stream_id) — it does not block readers of the MV.

module Trends
  class LatestTihRefreshWorker
    include Sidekiq::Job
    sidekiq_options queue: :post_stream, retry: 3

    LOCK_KEY = "latest_tih_mv_refresh"

    def perform(_stream_id = nil)
      return Rails.logger.info("Trends::LatestTihRefreshWorker: refresh already in progress — skip") unless acquire_lock

      begin
        ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY latest_tih_per_stream")
        Rails.logger.info("Trends::LatestTihRefreshWorker: latest_tih_per_stream refreshed")
      ensure
        release_lock
      end
    end

    private

    def acquire_lock
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(hashtext(?))", LOCK_KEY ])
      )
    end

    def release_lock
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtext(?))", LOCK_KEY ])
      )
    rescue StandardError => e
      Rails.logger.warn("Trends::LatestTihRefreshWorker: advisory unlock failed — #{e.class}")
    end
  end
end
