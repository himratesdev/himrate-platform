# frozen_string_literal: true

# TASK-038 FR-018: TI drop detection over configurable window (default 7d).
# Returns delta_pts (latest - N days ago). Negative = drop. nil if insufficient history.
# Polling pattern (Option A).

module Hs
  class TiDropDetector
    def call(channel)
      window_days = ti_drop_window_days

      latest = TrustIndexHistory
        .where(channel_id: channel.id)
        .order(calculated_at: :desc)
        .pick(:trust_index_score)

      baseline = TrustIndexHistory
        .where(channel_id: channel.id)
        .where("calculated_at <= ?", window_days.days.ago)
        .order(calculated_at: :desc)
        .pick(:trust_index_score)

      return nil unless latest && baseline

      (latest.to_f - baseline.to_f).round(2)
    end

    def ti_drop_window_days
      SignalConfiguration
        .where(signal_type: "recommendation", category: "default", param_name: "ti_drop_window_days")
        .pick(:param_value)&.to_i || 7
    end

    def ti_drop_threshold_pts
      SignalConfiguration
        .where(signal_type: "recommendation", category: "default", param_name: "ti_drop_threshold_pts")
        .pick(:param_value)&.to_f || 15.0
    end
  end
end
