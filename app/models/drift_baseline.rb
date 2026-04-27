# frozen_string_literal: true

# BUG-010 PR3: heuristic baseline для drift forecast (per (destination, accessory) pair).
# Computed by MlOps::DriftForecastTrainerService weekly. Read by InferenceService daily.
# Replaces sklearn pickle artifact (ADR DEC-13 corrigendum — pure Ruby для нашего scale).

class DriftBaseline < ApplicationRecord
  ALGORITHM_VERSION = "ruby_heuristic_v1"
  MIN_SAMPLES = 5 # минимум events required для valid baseline (ниже = insufficient data)

  validates :destination, :accessory, :algorithm_version, :computed_at, presence: true
  validates :destination, uniqueness: { scope: :accessory }
  validates :sample_count, numericality: { greater_than_or_equal_to: 0 }
  validates :mean_interval_seconds, numericality: { greater_than: 0, allow_nil: true }
  validates :stddev_interval_seconds, numericality: { greater_than_or_equal_to: 0, allow_nil: true }

  scope :for_pair, ->(destination, accessory) { where(destination: destination, accessory: accessory) }

  def sufficient_data?
    sample_count >= MIN_SAMPLES && mean_interval_seconds.present?
  end
end
