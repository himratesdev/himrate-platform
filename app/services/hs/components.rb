# frozen_string_literal: true

# TASK-038 FR-002..008: BFT-compliant component formulas.
# Pure functions — no persistence, no external state beyond DB reads.

module Hs
  class Components
    PERIOD = 30.days
    MIN_STREAMS_FULL = 7

    def initialize(channel)
      @channel = channel
    end

    def compute(stream_count:)
      return {} if stream_count.zero?

      cutoff = PERIOD.ago

      {
        ti: ti_component(cutoff),
        stability: stability_component(cutoff, stream_count),
        engagement: engagement_component(cutoff, stream_count),
        growth: growth_component(cutoff, stream_count),
        consistency: consistency_component(cutoff, stream_count)
      }
    end

    # FR-006: avg(TI) over 30d
    def ti_component(cutoff)
      avg = TrustIndexHistory
        .where(channel_id: @channel.id)
        .where("calculated_at > ?", cutoff)
        .average(:trust_index_score)
      avg&.to_f&.round(2)
    end

    # FR-005 (FIX): Stability = 100 × (1 - CV(CCV)), CV = std/mean of streams.avg_ccv
    def stability_component(cutoff, stream_count)
      return nil if stream_count < MIN_STREAMS_FULL

      stats = @channel.streams
        .where.not(ended_at: nil)
        .where("ended_at > ?", cutoff)
        .where("avg_ccv > 0")
        .pick(
          Arel.sql("AVG(avg_ccv)"),
          Arel.sql("STDDEV(avg_ccv)")
        )

      mean = stats&.first&.to_f
      stddev = stats&.last&.to_f
      return nil unless mean && stddev && mean > 0

      cv = stddev / mean
      (100.0 * (1.0 - cv)).round(2).clamp(0.0, 100.0)
    end

    # FR-002: Engagement = min(100, (chat_msg_per_min / avg_ccv) × 1000)
    # Aggregate across 30d streams, then compute.
    def engagement_component(cutoff, stream_count)
      return nil if stream_count < 3

      # S3 fix: single query — JOIN streams with chat_messages count.
      # Returns [{id, duration_ms, avg_ccv, message_count}, ...] in one trip.
      rows = @channel.streams
        .where.not(ended_at: nil)
        .where("ended_at > ?", cutoff)
        .where("avg_ccv > 0 AND duration_ms > 0")
        .joins("LEFT JOIN chat_messages cm ON cm.stream_id = streams.id")
        .group("streams.id, streams.duration_ms, streams.avg_ccv")
        .pluck(
          "streams.duration_ms",
          "streams.avg_ccv",
          Arel.sql("COUNT(cm.id)")
        )

      ratios = rows.map do |duration_ms, avg_ccv, msg_count|
        duration_min = duration_ms.to_f / 60_000.0
        next nil if duration_min <= 0 || msg_count.to_i.zero?

        # Streams without chat records = IRC not monitoring, skip (not bias downward).
        msg_per_min = msg_count.to_f / duration_min
        (msg_per_min / avg_ccv.to_f) * 1000.0
      end.compact

      return nil if ratios.empty?

      avg_score = ratios.sum / ratios.size
      avg_score.round(2).clamp(0.0, 100.0)
    end

    # FR-003: Growth = min(100, log₁₀(1 + max(0, Δfollowers_30d)) × 20)
    # Absolute formula (not category-relative).
    def growth_component(cutoff, stream_count)
      return nil if stream_count < MIN_STREAMS_FULL

      snapshots = FollowerSnapshot
        .where(channel_id: @channel.id)
        .where("timestamp > ?", cutoff)
        .order(:timestamp)
        .pluck(:followers_count)

      return nil if snapshots.size < 2

      delta = [ snapshots.last.to_i - snapshots.first.to_i, 0 ].max
      score = 20.0 * Math.log10(1 + delta)
      score.round(2).clamp(0.0, 100.0)
    end

    # FR-004: Consistency = (distinct_stream_days / 30) × 100
    def consistency_component(cutoff, stream_count)
      return nil if stream_count < MIN_STREAMS_FULL

      distinct_days = @channel.streams
        .where("started_at > ?", cutoff)
        .pluck(Arel.sql("DISTINCT DATE(started_at)"))
        .size

      ((distinct_days.to_f / 30.0) * 100).round(2).clamp(0.0, 100.0)
    end
  end
end
