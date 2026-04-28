# frozen_string_literal: true

# BUG-010 PR3 CR N-3: ML drift forecast confidence thresholds → DB-driven
# (SignalConfiguration). Per build-for-years, hardcoded numerical thresholds
# должны быть admin-tunable без code change.

class SeedMlDriftForecastConfidenceConfig < ActiveRecord::Migration[8.1]
  def up
    require Rails.root.join("db/seeds/ml_drift_forecast.rb")
    MlDriftForecastSeeds.call
  end

  def down
    SignalConfiguration.where(signal_type: "ml_drift_forecast", category: "confidence").delete_all
  end
end
