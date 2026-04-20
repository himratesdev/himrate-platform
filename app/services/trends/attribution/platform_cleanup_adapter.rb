# frozen_string_literal: true

# TASK-039 FR-022: Platform cleanup attribution — detects mass follower drops
# correlated across multiple channels (Twitch platform-wide bot purge events).
#
# Detection logic:
#   1. Найти FollowerSnapshot для channel на anomaly.timestamp ±24h window
#   2. Compute daily delta (followers_count diff vs previous day's snapshot)
#   3. Normalize as fraction: |delta| / previous_count
#   4. Match если fraction > cleanup_drop_threshold (SignalConfiguration, default 5%)
#   5. Confidence = min(1.0, drop_fraction / cleanup_confidence_normalizer) — clamp
#
# Thresholds в SignalConfiguration (trust_index/platform_cleanup/*) — build-for-years
# admin tunable (if Twitch changes cleanup cadence или threshold calibration needs).

module Trends
  module Attribution
    class PlatformCleanupAdapter < BaseAdapter
      SIGNAL_TYPE = "trust_index"
      CONFIG_CATEGORY = "platform_cleanup"

      protected

      def build_attribution(anomaly)
        channel_id = anomaly.stream.channel_id
        anomaly_time = anomaly.timestamp

        # Find snapshot closest to anomaly_time (within 24h window)
        latest_snapshot = FollowerSnapshot
          .where(channel_id: channel_id)
          .where(timestamp: (anomaly_time - 24.hours)..anomaly_time)
          .order(timestamp: :desc)
          .first
        return nil if latest_snapshot.nil?

        # Previous day snapshot для delta compute
        previous_snapshot = FollowerSnapshot
          .where(channel_id: channel_id)
          .where("timestamp < ?", latest_snapshot.timestamp)
          .order(timestamp: :desc)
          .first
        return nil if previous_snapshot.nil?

        previous_count = previous_snapshot.followers_count
        return nil if previous_count.to_i.zero?

        delta = latest_snapshot.followers_count - previous_count
        return nil if delta >= 0 # no drop

        drop_fraction = delta.abs.to_f / previous_count
        return nil if drop_fraction < drop_threshold

        {
          source: "platform_cleanup",
          confidence: (drop_fraction / confidence_normalizer).clamp(0.0, 1.0),
          raw_source_data: {
            followers_before: previous_count,
            followers_after: latest_snapshot.followers_count,
            delta: delta,
            drop_fraction: drop_fraction.round(4),
            snapshot_timestamp: latest_snapshot.timestamp.iso8601
          }
        }
      end

      private

      def drop_threshold
        @drop_threshold ||= SignalConfiguration.value_for(
          SIGNAL_TYPE, CONFIG_CATEGORY, "cleanup_drop_threshold"
        ).to_f
      end

      def confidence_normalizer
        @confidence_normalizer ||= SignalConfiguration.value_for(
          SIGNAL_TYPE, CONFIG_CATEGORY, "cleanup_confidence_normalizer"
        ).to_f
      end
    end
  end
end
