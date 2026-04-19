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
  validate :source_is_known

  scope :attributed, -> { where.not(source: "unattributed") }
  scope :by_confidence, -> { order(confidence: :desc) }
  scope :for_source, ->(source) { where(source: source) }

  # Lookup canonical AttributionSource (для display labels, etc.).
  # Lazy — не FK, чтобы избежать coupling при rename source string.
  def source_config
    AttributionSource.find_by(source: source)
  end

  private

  # Validates source против cached AttributionSource.known_sources (10min TTL).
  # Предотвращает silent typos в workers (e.g. "raid_bbot").
  def source_is_known
    return if source.blank? # handled by presence validation
    return if AttributionSource.known_sources.include?(source)

    errors.add(:source, "'#{source}' is not a known attribution source")
  end
end
