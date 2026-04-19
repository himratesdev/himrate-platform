# frozen_string_literal: true

# TASK-039 FR-016: Output of attribution pipeline.
# Один anomaly может иметь multiple attributions от разных sources.
# UNIQUE (anomaly_id, source) — повторный run pipeline = upsert.

class AnomalyAttribution < ApplicationRecord
  belongs_to :anomaly

  validates :source, presence: true
  validates :confidence, presence: true, numericality: { in: 0..1 }
  validates :attributed_at, presence: true
  validates :anomaly_id, uniqueness: { scope: :source }

  scope :attributed, -> { where.not(source: "unattributed") }
  scope :by_confidence, -> { order(confidence: :desc) }
  scope :for_source, ->(source) { where(source: source) }

  # Lookup canonical AttributionSource (для display labels, etc.).
  # Lazy — не FK, чтобы избежать coupling при rename source string.
  def source_config
    AttributionSource.find_by(source: source)
  end
end
