# frozen_string_literal: true

# TASK-039 Phase C2: SignalConfiguration rows для StabilityEndpointService +
# PeerComparisonService. Build-for-years: все thresholds admin-tunable без deploy.

class SeedTrendsStabilityAndPeerConfigs < ActiveRecord::Migration[8.0]
  CONFIGS = [
    # === Stability (FR-003, BR-008) ===
    # score = 1 - CV(TI, period). Thresholds: stable ≥0.85, moderate 0.65-0.84, volatile <0.65.
    [ "trends", "stability", "stable_min_score", 0.85 ],
    [ "trends", "stability", "moderate_min_score", 0.65 ],
    [ "trends", "stability", "min_streams_required", 7 ], # SRS Edge Case #2

    # === Peer Comparison (FR-007, FR-014) ===
    # Min channels per category чтобы percentile был meaningful (SRS US-009).
    [ "trends", "peer_comparison", "min_category_channels", 100 ],
    [ "trends", "peer_comparison", "cache_ttl_minutes", 15 ]
  ].freeze

  def up
    now = Time.current
    rows = CONFIGS.map do |signal_type, category, param_name, param_value|
      { signal_type: signal_type, category: category, param_name: param_name, param_value: param_value,
        created_at: now, updated_at: now }
    end
    SignalConfiguration.upsert_all(rows,
      unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  def down
    CONFIGS.each do |signal_type, category, param_name, _|
      SignalConfiguration.where(
        signal_type: signal_type, category: category, param_name: param_name
      ).delete_all
    end
  end
end
