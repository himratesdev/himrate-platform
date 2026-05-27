# frozen_string_literal: true

# TASK-113 (FR-007): client-captured engagement event (M7 log + M9 input).
# Source = extension content-script (свои cheer/sub/follow/hype-действия) — DSV option B.
# event_hash = SHA256 idempotency (как SyncEvent): дубликат → один раз (insert_all on_conflict).
class PvaEngagementEvent < ApplicationRecord
  EVENT_TYPES = %w[sub cheer follow hype_contribution].freeze
  SOURCES = %w[client_capture helix].freeze

  belongs_to :user

  validates :user_id, presence: true
  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :event_hash, presence: true, length: { is: 64 }, uniqueness: { scope: :user_id }
  validates :occurred_at, presence: true
  validates :amount, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :recent, ->(limit = 100) { order(occurred_at: :desc).limit(limit) }
  scope :of_type, ->(type) { where(event_type: type) }

  # Deterministic idempotency key (same event from same device twice → one row).
  def self.compute_hash(user_id:, event_type:, channel_id:, occurred_at:)
    bucket = occurred_at.utc.change(sec: 0).iso8601
    Digest::SHA256.hexdigest("#{user_id}|#{event_type}|#{channel_id}|#{bucket}")
  end
end
