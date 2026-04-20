# frozen_string_literal: true

# TASK-039 FR-032: Identifies best/worst stream in period by latest TI score.
# Output consumed by /trends/erv + /trends/trust-index endpoints (summary cards).
# Also marks trends_daily_aggregates.{is_best_stream_day, is_worst_stream_day}
# via DailyBuilder extension (lazy, recomputed on aggregation run).
#
# Strategy: rank TrustIndexHistory rows by trust_index_score within [from, to],
# tie-break by calculated_at DESC (most recent stream wins).
#
# Minimum streams threshold в SignalConfiguration (trends/best_worst/min_streams_required)
# — below threshold returns nil pair (insufficient data signal to API/UI).

module Trends
  module Analysis
    class BestWorstStreamFinder
      def self.call(channel:, from:, to:)
        new(channel: channel, from: from, to: to).call
      end

      def initialize(channel:, from:, to:)
        @channel = channel
        @from = from
        @to = to
      end

      def call
        min_streams = SignalConfiguration.value_for("trends", "best_worst", "min_streams_required").to_i

        scope = TrustIndexHistory
          .for_channel(@channel.id)
          .where(calculated_at: @from..@to)
          .where.not(trust_index_score: nil)
          .where.not(stream_id: nil)

        return { best: nil, worst: nil, insufficient_data: true } if scope.count < min_streams

        best = scope.order(trust_index_score: :desc, calculated_at: :desc).first
        worst = scope.order(trust_index_score: :asc, calculated_at: :asc).first

        {
          best: summarize(best),
          worst: summarize(worst),
          insufficient_data: false
        }
      end

      private

      def summarize(tih)
        return nil unless tih

        stream = tih.stream
        {
          stream_id: tih.stream_id,
          date: tih.calculated_at.to_date,
          ti: tih.trust_index_score.to_f.round(2),
          erv_percent: tih.erv_percent&.to_f&.round(2),
          classification: tih.classification,
          game_name: stream&.game_name,
          started_at: stream&.started_at,
          ended_at: stream&.ended_at
        }
      end
    end
  end
end
