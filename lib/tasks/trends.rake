# frozen_string_literal: true

# TASK-039 backfill rake tasks.
namespace :trends do
  # FR-046 foundation: backfill qualifying percentile snapshots для existing
  # trust_index_history rows missing snapshots. Iterates batches, idempotent.
  #
  # Usage:
  #   rake trends:backfill_qualifying_percentiles                       # all missing
  #   rake trends:backfill_qualifying_percentiles[2026-01-01]           # since date
  #   rake trends:backfill_qualifying_percentiles[2026-01-01,2026-04-01] # range
  #
  # Skip rows already snapshotted (engagement_percentile_at_end IS NOT NULL OR
  # engagement_consistency_percentile_at_end IS NOT NULL — partial fills allowed
  # if HS or Reputation data was missing на момент snapshot, повторный backfill
  # пытается снова).
  desc "Backfill engagement + engagement_consistency percentile snapshots в trust_index_histories"
  task :backfill_qualifying_percentiles, %i[since until] => :environment do |_t, args|
    since_date = args[:since].present? ? Date.parse(args[:since]).beginning_of_day : nil
    until_date = args[:until].present? ? Date.parse(args[:until]).end_of_day : Time.current

    scope = TrustIndexHistory.where.not(stream_id: nil)
    scope = scope.where(calculated_at: since_date..until_date) if since_date
    scope = scope.where(calculated_at: ..until_date) unless since_date

    # Только rows без обоих snapshots — skip уже complete для idempotency
    scope = scope.where(
      "engagement_percentile_at_end IS NULL OR engagement_consistency_percentile_at_end IS NULL"
    )

    total = scope.count
    puts "Backfilling #{total} TIH rows..."

    processed = 0
    enqueued = 0

    scope.find_each(batch_size: 500) do |tih|
      Trends::QualifyingPercentileSnapshotWorker.perform_async(tih.stream_id)
      enqueued += 1
      processed += 1
      puts "  ... #{processed}/#{total} enqueued" if (processed % 1000).zero?
    end

    puts "Done: #{enqueued} jobs enqueued. Monitor Sidekiq для completion."
  end
end
