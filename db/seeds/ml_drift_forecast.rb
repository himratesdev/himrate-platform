# frozen_string_literal: true

# BUG-010 PR3 CR N-3: idempotent seed loader для ML drift forecast confidence config
# (SignalConfiguration). Used:
#   - Migration 20260428100003: production data load
#   - rails_helper.rb: test environment data load (maintain_test_schema! не runs migration up blocks)

module MlDriftForecastSeeds
  ROWS = [
    { signal_type: "ml_drift_forecast", category: "confidence",
      param_name: "sample_threshold_low",  param_value: 5 },
    { signal_type: "ml_drift_forecast", category: "confidence",
      param_name: "sample_threshold_mid",  param_value: 10 },
    { signal_type: "ml_drift_forecast", category: "confidence",
      param_name: "sample_threshold_high", param_value: 30 },
    { signal_type: "ml_drift_forecast", category: "confidence",
      param_name: "level_low",  param_value: 0.50 },
    { signal_type: "ml_drift_forecast", category: "confidence",
      param_name: "level_mid",  param_value: 0.70 },
    { signal_type: "ml_drift_forecast", category: "confidence",
      param_name: "level_high", param_value: 0.85 },
    { signal_type: "ml_drift_forecast", category: "confidence",
      param_name: "min_for_persist", param_value: 0.60 }
  ].freeze

  def self.call
    ROWS.each do |row|
      SignalConfiguration.find_or_create_by!(
        signal_type: row[:signal_type],
        category: row[:category],
        param_name: row[:param_name]
      ) { |c| c.param_value = row[:param_value] }
    end
  end
end
