# frozen_string_literal: true

# TASK-039 Phase B1b FR-022: SignalConfiguration seeds для Trends::Attribution::PlatformCleanupAdapter.
# Build-for-years: admin tunable detection thresholds. Initial values calibrated
# conservatively — Twitch platform cleanup events observed ~5-10% drop magnitude
# в historical data.
#
#   cleanup_drop_threshold=0.05 — minimum fraction (5%) чтобы attribute anomaly
#     к platform cleanup. Normal follower churn typically <1%.
#   cleanup_confidence_normalizer=0.10 — drop_fraction / normalizer = confidence.
#     10% drop → confidence=1.0 (clamped). 5% drop → confidence=0.5.

class SeedPlatformCleanupThresholds < ActiveRecord::Migration[8.0]
  SEEDS = [
    { param_name: "cleanup_drop_threshold", param_value: 0.05 },
    { param_name: "cleanup_confidence_normalizer", param_value: 0.10 }
  ].freeze

  def up
    now = Time.current
    rows = SEEDS.map do |seed|
      {
        signal_type: "trust_index",
        category: "platform_cleanup",
        param_name: seed[:param_name],
        param_value: seed[:param_value],
        created_at: now,
        updated_at: now
      }
    end

    SignalConfiguration.upsert_all(rows, unique_by: %i[signal_type category param_name])
  end

  def down
    SignalConfiguration.where(
      signal_type: "trust_index",
      category: "platform_cleanup"
    ).delete_all
  end
end
