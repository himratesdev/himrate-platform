# frozen_string_literal: true

# TASK-039 FR-003: GET /api/v1/channels/:id/trends/stability — M3 Channel Stability.
# Response per SRS §4.1: score + label + CV + TI mean/std + peer_comparison (conditional).
#
# Stability score = 1 - CV(TI) = 1 - (ti_std / ti_avg). BR-008:
#   stable     ≥ stable_min_score   (default 0.85)
#   moderate   ≥ moderate_min_score (0.65-0.84)
#   volatile   < moderate           (<0.65)
#
# Minimum streams threshold (SignalConfig trends/stability/min_streams_required, default 7 — SRS
# Edge Case #2). Ниже → insufficient_data, skip compute.
#
# Peer comparison (Business-only — SRS US-016): optional `include_peer_comparison=true`.
# Controller enforces ChannelPolicy#view_peer_comparison? через before_action match.

module Trends
  module Api
    class StabilityEndpointService < BaseEndpointService
      def initialize(channel:, period:, granularity: nil, include_peer_comparison: false, user: nil)
        super(channel: channel, period: period, granularity: granularity, user: user)
        @include_peer_comparison = ActiveModel::Type::Boolean.new.cast(include_peer_comparison)
      end

      def call
        from_ts, to_ts = range
        aggregates = fetch_aggregates(from_ts, to_ts)

        min_streams = SignalConfiguration.value_for("trends", "stability", "min_streams_required").to_i
        if aggregates[:streams_count] < min_streams
          return {
            data: insufficient_payload(from_ts, to_ts, aggregates, min_streams, reason: "streams_below_min"),
            meta: meta
          }
        end

        stable_min = SignalConfiguration.value_for("trends", "stability", "stable_min_score").to_f
        moderate_min = SignalConfiguration.value_for("trends", "stability", "moderate_min_score").to_f
        score = compute_score(aggregates[:ti_avg], aggregates[:ti_std])

        # CR S-3: edge case — ti_avg=0 (fraudulent channel all-zero) проходит streams guard,
        # но compute_score returns nil (division by zero). Treat as insufficient_data
        # consistently instead of mixed {score: nil, insufficient_data: false} payload.
        if score.nil?
          return {
            data: insufficient_payload(from_ts, to_ts, aggregates, min_streams, reason: "ti_avg_zero_or_null"),
            meta: meta
          }
        end

        label = classify_score(score, stable_min, moderate_min)

        payload = {
          channel_id: channel.id,
          period: period,
          from: from_ts.iso8601,
          to: to_ts.iso8601,
          score: score,
          label: label,
          cv: compute_cv(aggregates[:ti_avg], aggregates[:ti_std]),
          ti_mean: aggregates[:ti_avg],
          ti_std: aggregates[:ti_std],
          streams_count: aggregates[:streams_count],
          insufficient_data: false
        }

        if @include_peer_comparison
          category = latest_category
          payload[:peer_comparison] = category ? Trends::Analysis::PeerComparisonService.call(
            channel: channel, category: category, period: period
          ) : nil
        end

        { data: payload, meta: meta }
      end

      private

      def fetch_aggregates(from_ts, to_ts)
        stats = TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where.not(ti_avg: nil)
          .pick(
            Arel.sql("AVG(ti_avg)"),
            Arel.sql("AVG(ti_std)"),
            Arel.sql("SUM(streams_count)")
          )
        stats ||= [ nil, nil, 0 ]
        {
          ti_avg: stats[0]&.to_f&.round(2),
          ti_std: stats[1]&.to_f&.round(2),
          streams_count: stats[2].to_i
        }
      end

      def compute_score(ti_avg, ti_std)
        return nil if ti_avg.nil? || ti_std.nil? || ti_avg.zero?

        (1.0 - ti_std / ti_avg).clamp(0.0, 1.0).round(3)
      end

      def compute_cv(ti_avg, ti_std)
        return nil if ti_avg.nil? || ti_std.nil? || ti_avg.zero?

        (ti_std / ti_avg).round(3)
      end

      def classify_score(score, stable_min, moderate_min)
        return nil if score.nil?
        return "stable" if score >= stable_min
        return "moderate" if score >= moderate_min

        "volatile"
      end

      def insufficient_payload(from_ts, to_ts, aggregates, min_streams, reason:)
        {
          channel_id: channel.id,
          period: period,
          from: from_ts.iso8601,
          to: to_ts.iso8601,
          score: nil,
          label: "insufficient_data",
          cv: nil,
          ti_mean: aggregates[:ti_avg],
          ti_std: aggregates[:ti_std],
          streams_count: aggregates[:streams_count],
          insufficient_data: true,
          reason: reason,
          min_streams_required: min_streams
        }
      end

      def latest_category
        latest_category_for_channel
      end
    end
  end
end
