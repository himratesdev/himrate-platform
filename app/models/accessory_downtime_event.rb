# frozen_string_literal: true

# BUG-010 PR2: accessory downtime tracking — input для CostAttribution::DowntimeCostCalculator.
# Hooks INSERT on each restart/health_fail/rollback. Calculator returns $0 если revenue_baseline empty.

class AccessoryDowntimeEvent < ApplicationRecord
  SOURCES = %w[drift restart health_fail rollback].freeze

  belongs_to :drift_event, class_name: "AccessoryDriftEvent", optional: true

  validates :destination, :accessory, :started_at, :source, presence: true
  validates :source, inclusion: { in: SOURCES }

  before_save :compute_duration_seconds

  scope :recent, ->(window = 30.days) { where(started_at: window.ago..) }

  private

  def compute_duration_seconds
    return unless ended_at && started_at
    self.duration_seconds = (ended_at - started_at).to_i
  end
end
