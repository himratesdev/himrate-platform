# frozen_string_literal: true

# BUG-010 PR2: ML forecasted drift events (dormant pre-launch).
# MlOps::DriftForecastInferenceService инсертит predictions daily after MlOps::DriftForecastTrainerService
# trains model (weekly cron, dormant до accessory_drift_events count >=50).

class DriftForecastPrediction < ApplicationRecord
  validates :destination, :accessory, :predicted_drift_at, :model_version, :generated_at, presence: true
  validates :confidence, numericality: { in: 0.0..1.0, allow_nil: true }

  scope :upcoming, ->(window = 30.days) { where(predicted_drift_at: Time.current..(Time.current + window)) }
  scope :high_confidence, -> { where("confidence >= ?", 0.6) }
end
