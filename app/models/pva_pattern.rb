# frozen_string_literal: true

# TASK-113 (FR-010, M11): behavioral pattern insight-card. v1 rule-based; sentiment_enabled ML-hook.
class PvaPattern < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :pattern_type, presence: true
  validates :title, presence: true
  validates :body, presence: true
  validates :confidence, numericality: { in: 0..1, allow_nil: true }
  validates :computed_at, presence: true

  scope :for_user, ->(user) { where(user_id: user.id) }
end
