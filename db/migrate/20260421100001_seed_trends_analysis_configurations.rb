# frozen_string_literal: true

# TASK-039 Phase B3: Additional SignalConfiguration rows для analysis services,
# которые не были засеяны в Phase A1 (migration 20260419100006).
#
# Coverage:
#   - trends/coupling (FR-030): rolling window + health bands + min history.
#   - trends/anomaly_freq: baseline_lookback_ratio (defaults 1.0 → previous period).
#   - trends/best_worst: min_streams threshold (FR-032).
#   - trends/tier_change: lookback_days (FR-033, default=period length).
#   - trends/insights: p0_degradation_threshold_pts (FR-034).
#
# Build-for-years: все thresholds tunable через admin DB updates, no code deploy.

class SeedTrendsAnalysisConfigurations < ActiveRecord::Migration[8.0]
  CONFIGS = [
    # === FollowerCcvCouplingTimeline (FR-030) ===
    [ "trends", "coupling", "rolling_window_days", 30 ],
    [ "trends", "coupling", "healthy_r_min", 0.7 ],
    [ "trends", "coupling", "weakening_r_min", 0.3 ],
    [ "trends", "coupling", "min_history_days", 7 ],

    # === AnomalyFrequencyScorer (FR-031) ===
    [ "trends", "anomaly_freq", "baseline_lookback_ratio", 1.0 ],
    [ "trends", "anomaly_freq", "min_baseline_streams", 3 ],
    # Severity derived from `confidence` column (no dedicated severity). medium+ threshold.
    [ "trends", "anomaly_freq", "min_confidence_threshold", 0.4 ],

    # === BestWorstStreamFinder (FR-032) ===
    [ "trends", "best_worst", "min_streams_required", 3 ],

    # === MovementInsights priority thresholds (FR-034 extension) ===
    [ "trends", "insights", "p0_ti_delta_min_pts", 5.0 ],
    [ "trends", "insights", "p1_tier_change_recency_days", 30 ]
  ].freeze

  def up
    now = Time.current
    rows = CONFIGS.map do |signal_type, category, param_name, param_value|
      {
        signal_type: signal_type,
        category: category,
        param_name: param_name,
        param_value: param_value,
        created_at: now,
        updated_at: now
      }
    end

    SignalConfiguration.upsert_all(rows,
      unique_by: %i[signal_type category param_name],
      on_duplicate: :skip)
  end

  def down
    CONFIGS.each do |signal_type, category, param_name, _|
      SignalConfiguration.where(
        signal_type: signal_type, category: category, param_name: param_name
      ).delete_all
    end
  end
end
