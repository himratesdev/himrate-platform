# frozen_string_literal: true

# TASK-039 Phase A3a (FR-046 foundation): Snapshot qualifying percentiles
# в trust_index_history AT STREAM END.
#
# Triggered by PostStreamWorker via perform_in(2.minutes, stream_id) после того
# как HealthScoreRefreshWorker + StreamerReputationRefreshWorker complete.
# Delay buffer гарантирует что HS + Reputation freshly computed на момент
# percentile lookup (refreshes typically <30s).
#
# Idempotent: UPDATE existing trust_index_history row (latest для stream).
# Re-run safe (overwrites with current values).
#
# Why latest TIH per stream (не all rows для stream):
# Bonus accelerator iterates clean streams (TI ≥ 50) — needs ОДИН snapshot
# на stream. Latest TIH row reflects final post-stream computation.
#
# Stored fields (все nullable — graceful если nil percentile или нет
# reputation/HS data на момент стрима):
#   - engagement_percentile_at_end (Hs::ComponentPercentileService :engagement)
#   - engagement_consistency_percentile_at_end (Reputation::ComponentPercentileService :engagement_consistency)
#   - category_at_end (mapped через Hs::CategoryMapper)

module Trends
  class QualifyingPercentileSnapshotWorker
    include Sidekiq::Job
    sidekiq_options queue: :post_stream, retry: 3

    # Custom error для retry-on-race-condition (vs silent no-op для legitimate skips).
    class TihNotReady < StandardError; end

    def perform(stream_id)
      stream = Stream.find_by(id: stream_id)
      return unless stream # legitimate skip — stream удалён

      tih = TrustIndexHistory
        .for_channel(stream.channel_id)
        .where(stream_id: stream.id)
        .order(calculated_at: :desc)
        .first

      # CR N-1: TIH должна существовать после run_final_compute в PostStreamWorker.
      # Если absent на 2-min mark — race condition (HS/Reputation refresh slow или
      # final compute failed). Raise → Sidekiq retry 3 attempts (15s/30s/75s backoff,
      # ~2 min retry window). Backfill rake catches остатки если все retries fail.
      raise TihNotReady, "TIH не найдена для stream #{stream.id} (race с post-stream compute)" unless tih

      category_key = Hs::CategoryMapper.map(stream.game_name)
      channel = stream.channel

      hs_percentiles = Hs::ComponentPercentileService.new(channel).call(category_key)
      rep_percentiles = Reputation::ComponentPercentileService.new(channel).call(category_key)

      tih.update_columns(
        engagement_percentile_at_end: hs_percentiles&.dig(:engagement),
        engagement_consistency_percentile_at_end: rep_percentiles&.dig(:engagement_consistency),
        category_at_end: category_key
      )

      Rails.logger.info(
        "QualifyingPercentileSnapshotWorker: stream #{stream_id} channel #{channel.id} " \
        "category=#{category_key} eng=#{hs_percentiles&.dig(:engagement)} " \
        "eng_cons=#{rep_percentiles&.dig(:engagement_consistency)}"
      )
    end
  end
end
