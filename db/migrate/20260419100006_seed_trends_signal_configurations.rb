# frozen_string_literal: true

# TASK-039: Seed signal_configurations для Trends services.
# Build-for-years: ВСЕ thresholds в DB, no hardcoded constants.
# Включает rehab_bonus_* (BUG-009 absorbed по ADR §4.9).

class SeedTrendsSignalConfigurations < ActiveRecord::Migration[8.0]
  CONFIGS = [
    # === Forecast Service (FR-026, ADR §4.4) ===
    [ "trends", "forecast", "reliability_high_r2", 0.7 ],
    [ "trends", "forecast", "reliability_medium_r2", 0.4 ],
    [ "trends", "forecast", "horizon_days_short", 7 ],
    [ "trends", "forecast", "horizon_days_long", 30 ],
    [ "trends", "forecast", "min_points_for_forecast", 14 ],

    # === DiscoveryPhaseDetector (FR-029, ADR §4.5) ===
    [ "trends", "discovery", "logistic_r2_organic_min", 0.7 ],
    [ "trends", "discovery", "step_r2_burst_min", 0.9 ],
    [ "trends", "discovery", "burst_window_days_max", 3 ],
    [ "trends", "discovery", "burst_jump_min", 1000 ],
    [ "trends", "discovery", "channel_age_max_days", 60 ],
    [ "trends", "discovery", "min_data_points", 7 ],

    # === MovementInsights priority (FR-034, ADR §4.6) ===
    [ "trends", "insights", "top_n_count", 3 ],
    [ "trends", "insights", "p0_threshold", 0.8 ],
    [ "trends", "insights", "p1_threshold", 0.5 ],
    [ "trends", "insights", "p2_threshold", 0.3 ],
    [ "trends", "insights", "recency_decay_lambda", 0.05 ],

    # === TrendCalculator (FR-024, ADR §4.7) ===
    [ "trends", "trend", "direction_rising_slope_min", 0.1 ],
    [ "trends", "trend", "direction_declining_slope_max", -0.1 ],
    [ "trends", "trend", "confidence_high_r2", 0.7 ],
    [ "trends", "trend", "confidence_medium_r2", 0.4 ],

    # === AnomalyFrequencyScorer (FR-031, ADR §4.8) ===
    [ "trends", "anomaly_freq", "elevated_threshold_pct", 50 ],
    [ "trends", "anomaly_freq", "reduced_threshold_pct", -20 ],

    # === Patterns (FR-027, ADR §4.10/4.11) ===
    [ "trends", "patterns", "weekday_pattern_min_days", 14 ],
    [ "trends", "patterns", "category_single_threshold_pct", 95 ],

    # === Cache versioning (ADR §4.12) ===
    [ "trends", "cache", "schema_version", 2 ],

    # === Rehabilitation Bonus Accelerator (FR-046/047, ADR §4.9, BUG-009 absorbed) ===
    [ "trust_index", "rehabilitation_bonus", "rehab_bonus_pts_max", 15 ],
    [ "trust_index", "rehabilitation_bonus", "rehab_bonus_per_qualifying_stream", 1 ],
    [ "trust_index", "rehabilitation_bonus", "rehab_bonus_percentile_threshold", 80 ],
    [ "trust_index", "rehabilitation_bonus", "rehab_bonus_acceleration_factor", 0.2 ]
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

    # N-6 CR iter 2: on_duplicate: :skip prevents перезапись admin-tuned values
    # при db:migrate:redo. На первом deploy — insert. На повторе — no-op.
    SignalConfiguration.upsert_all(rows,
      unique_by: %i[signal_type category param_name],
      on_duplicate: :skip)
  end

  def down
    SignalConfiguration.where(signal_type: "trends").delete_all
    SignalConfiguration.where(signal_type: "trust_index", category: "rehabilitation_bonus").delete_all
  end
end
