# frozen_string_literal: true

# TASK-110 FR-024..025: Dark period (когда user смотрел Twitch без extension active).
# Computed by TASK-187 separate worker (T1 backend stream) — TASK-110 ships table + reader.
# Surfaced via GET /api/v1/sync/snapshot.dark_period_markers[] → S3 banner UX.
class DarkPeriodMarker < ApplicationRecord
  self.table_name = "dark_period_markers"

  belongs_to :user

  validates :user_id, presence: true
  validates :period_start, presence: true
  validates :n_streams, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :m_channels, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :recent, ->(limit = 10) { order(period_start: :desc).limit(limit) }
end
