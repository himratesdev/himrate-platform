# frozen_string_literal: true

# BUG-010 PR2: ML drift forecasting predictions (dormant pre-launch).
# MlOps::DriftForecastInferenceService inserts predictions daily after MlOps::DriftForecastTrainerService
# trains model (weekly, требует ≥50 events accumulated). Drift Trend dashboard overlays predictions.

class CreateDriftForecastPredictions < ActiveRecord::Migration[8.0]
  def change
    create_table :drift_forecast_predictions, id: :uuid do |t|
      t.string :destination, null: false
      t.string :accessory, null: false
      t.timestamp :predicted_drift_at, null: false
      t.decimal :confidence, precision: 3, scale: 2
      t.string :model_version, null: false
      t.timestamp :generated_at, null: false
      t.timestamps
    end

    add_index :drift_forecast_predictions,
              [ :destination, :accessory, :predicted_drift_at ],
              name: "idx_predictions_lookup"
  end
end
