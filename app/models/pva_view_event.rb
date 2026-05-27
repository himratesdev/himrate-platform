# frozen_string_literal: true

# TASK-113 (FR-001..005): Personal Viewer Analytics viewing event (M1-M5 source).
# Partitioned by started_at (range). Populated by PersonalAnalytics::ViewAggregationWorker
# из SyncEvent stream_view. Append-only.
class PvaViewEvent < ApplicationRecord
  DEVICES = %w[desktop mobile tablet tv unknown].freeze

  belongs_to :user
  belongs_to :channel, optional: true

  validates :user_id, presence: true
  validates :started_at, presence: true
  validates :seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :in_window, ->(from, to) { where(started_at: from..to) }
end
