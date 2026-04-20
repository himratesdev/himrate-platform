# frozen_string_literal: true

# TASK-039 FR-031: Compares anomaly frequency current vs baseline (same-length
# preceding window). Output shape: {current_per_month, baseline_per_month,
# delta_percent, verdict, distribution: {by_day_of_week, by_type}}.
#
# Consumed by /trends/anomalies (frequency_score + distribution per SRS §4.3).
# Baseline window = [from - period_length × lookback_ratio, from] — ratio configurable.
#
# Minimum baseline streams threshold prevents misleading deltas (low baseline → huge %).
# If baseline insufficient → verdict="insufficient_baseline", delta_percent=nil.

module Trends
  module Analysis
    class AnomalyFrequencyScorer
      # Severity derived from `confidence` column (no dedicated severity column per
      # schema review). Threshold в SignalConfiguration — аналог severity ≥ medium.
      WEEKDAY_KEYS = %i[sun mon tue wed thu fri sat].freeze

      def self.call(channel:, from:, to:)
        new(channel: channel, from: from, to: to).call
      end

      def initialize(channel:, from:, to:)
        @channel = channel
        @from = from
        @to = to
      end

      def call
        ratio = SignalConfiguration.value_for("trends", "anomaly_freq", "baseline_lookback_ratio").to_f
        min_baseline = SignalConfiguration.value_for("trends", "anomaly_freq", "min_baseline_streams").to_i
        elevated_pct = SignalConfiguration.value_for("trends", "anomaly_freq", "elevated_threshold_pct").to_f
        reduced_pct = SignalConfiguration.value_for("trends", "anomaly_freq", "reduced_threshold_pct").to_f

        period_days = (@to.to_date - @from.to_date).to_i + 1
        baseline_days = (period_days * ratio).to_i.clamp(1, Float::INFINITY)
        baseline_to = @from - 1.second
        baseline_from = baseline_to - baseline_days.days

        current_anomalies = channel_anomalies(@from, @to)
        baseline_anomalies = channel_anomalies(baseline_from, baseline_to)

        current_count = current_anomalies.count
        baseline_count = baseline_anomalies.count

        current_per_month = rate_per_month(current_count, period_days)
        baseline_per_month = rate_per_month(baseline_count, baseline_days)

        insufficient_baseline = baseline_count < min_baseline
        delta_percent = insufficient_baseline || baseline_per_month.zero? ? nil : ((current_per_month - baseline_per_month) / baseline_per_month * 100).round(2)

        {
          current_per_month: current_per_month.round(2),
          baseline_per_month: baseline_per_month.round(2),
          delta_percent: delta_percent,
          verdict: verdict(delta_percent, elevated_pct, reduced_pct, insufficient_baseline),
          distribution: {
            by_day_of_week: distribution_by_dow(current_anomalies),
            by_type: distribution_by_type(current_anomalies)
          }
        }
      end

      private

      def channel_anomalies(from, to)
        min_confidence = SignalConfiguration.value_for("trends", "anomaly_freq", "min_confidence_threshold").to_f
        Anomaly
          .joins(:stream)
          .where(streams: { channel_id: @channel.id })
          .where(timestamp: from..to)
          .where("confidence IS NULL OR confidence >= ?", min_confidence)
      end

      def rate_per_month(count, days)
        return 0.0 if days.zero?

        count.to_f / days * 30.0
      end

      def verdict(delta_pct, elevated_pct, reduced_pct, insufficient)
        return "insufficient_baseline" if insufficient
        return "normal" if delta_pct.nil?
        return "elevated" if delta_pct >= elevated_pct
        return "reduced" if delta_pct <= reduced_pct

        "normal"
      end

      def distribution_by_dow(scope)
        rows = scope.pluck(Arel.sql("EXTRACT(DOW FROM timestamp)"))
        counts = Hash.new(0)
        rows.each { |dow| counts[WEEKDAY_KEYS[dow.to_i]] += 1 }
        WEEKDAY_KEYS.to_h { |k| [ k, counts[k] ] }
      end

      def distribution_by_type(scope)
        scope.group(:anomaly_type).count
      end
    end
  end
end
