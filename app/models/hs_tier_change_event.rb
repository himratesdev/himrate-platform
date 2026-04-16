# frozen_string_literal: true

# TASK-038 FR-030: HS Tier Change Events — extensible schema.
# event_type values: tier_change, category_change (future: significant_drop, significant_rise).
# Permanent retention (Big Data + notifications).

class HsTierChangeEvent < ApplicationRecord
  belongs_to :channel
  belongs_to :stream, optional: true

  EVENT_TYPES = %w[tier_change category_change significant_drop significant_rise].freeze

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :to_tier, presence: true
  validates :hs_after, presence: true, numericality: { in: 0..100 }
  validates :occurred_at, presence: true

  scope :tier_changes, -> { where(event_type: "tier_change") }
  scope :category_changes, -> { where(event_type: "category_change") }
  scope :recent, ->(days) { where("occurred_at > ?", days.days.ago) }
  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
end
