# frozen_string_literal: true

# TASK-A1 FR-012(a): nightly safety-net dispatcher for trends_daily_aggregates.
#
# The post-stream path (PostStreamWorker → Trends::AggregationWorker) covers the
# happy case. This cron re-aggregates *yesterday* for every channel that streamed,
# catching any post-stream aggregation that was missed or failed. AggregationWorker
# is idempotent (pg advisory lock + UPSERT) so re-runs are safe and cheap.
#
# Fan-out is throttled (mirrors trends:backfill_aggregates rake) to protect Redis
# and the :signals queue at scale (SRS §1.2 — 100k channels). Flipper-gated as a
# kill-switch for the batch fan-out (per CLAUDE.md "feature flags for production
# risks"; matches cleanup_worker gating).
module Trends
  class NightlyAggregationWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    THROTTLE_EVERY = 1_000
    THROTTLE_SECONDS = 0.05

    def perform
      return unless Flipper.enabled?(:trends_aggregation_nightly)

      date = Date.current - 1 # yesterday UTC (completed day)
      enqueued = enqueue_for_streamed_channels(date)
      emit_completed(date.to_s, enqueued)
    end

    private

    def enqueue_for_streamed_channels(date)
      enqueued = 0
      channel_ids_streamed_on(date).each do |channel_id|
        Trends::AggregationWorker.perform_async(channel_id, date.to_s)
        enqueued += 1
        sleep(THROTTLE_SECONDS) if (enqueued % THROTTLE_EVERY).zero?
      end
      enqueued
    end

    # Mirror DailyBuilder's date keying (streams_count ← Stream WHERE DATE(started_at)).
    def channel_ids_streamed_on(date)
      Stream.where(started_at: date.all_day).distinct.pluck(:channel_id)
    end

    def emit_completed(date_str, enqueued)
      Rails.logger.info(
        "Trends::NightlyAggregationWorker: enqueued #{enqueued} AggregationWorker jobs for #{date_str}"
      )
      ActiveSupport::Notifications.instrument(
        "trends.nightly_aggregation.completed",
        date: date_str,
        enqueued: enqueued
      )
    end
  end
end
