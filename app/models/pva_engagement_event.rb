# frozen_string_literal: true

# TASK-113 (FR-007): client-captured engagement event (M7 log + M9 input).
# Source = extension content-script (свои cheer/sub/follow/hype-действия) — DSV option B.
# Идемпотентность = client_event_id nonce (минтится extension'ом на каждое действие):
# event_hash = SHA256("user_id|client_event_id"). Ретрай → тот же nonce → один раз
# (insert_all on_conflict, idiom SyncEvent); разные действия → разные nonce → оба (CR SF-1).
class PvaEngagementEvent < ApplicationRecord
  EVENT_TYPES = %w[sub cheer follow hype_contribution].freeze
  SOURCES = %w[client_capture helix].freeze

  belongs_to :user

  validates :user_id, presence: true
  validates :client_event_id, presence: true
  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :event_hash, presence: true, length: { is: 64 }, uniqueness: { scope: :user_id }
  validates :occurred_at, presence: true
  validates :amount, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :recent, ->(limit = 100) { order(occurred_at: :desc).limit(limit) }
  scope :of_type, ->(type) { where(event_type: type) }

  # Idempotency key over the client-minted nonce only: the same action retried (even with
  # jittered timestamp/amount) hashes identically → one row; distinct actions → distinct hashes.
  def self.compute_hash(user_id:, client_event_id:)
    Digest::SHA256.hexdigest("#{user_id}|#{client_event_id}")
  end
end
