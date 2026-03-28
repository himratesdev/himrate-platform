# frozen_string_literal: true

class HealthScore < ApplicationRecord
  CONFIDENCE_LEVELS = %w[insufficient provisional_low provisional full deep].freeze

  belongs_to :channel
  belongs_to :stream, optional: true

  validates :health_score, presence: true
  validates :calculated_at, presence: true
  validates :confidence_level, inclusion: { in: CONFIDENCE_LEVELS }, allow_nil: true
end
