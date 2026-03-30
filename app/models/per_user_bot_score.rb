# frozen_string_literal: true

# TASK-027: Per-user bot score with classification.

class PerUserBotScore < ApplicationRecord
  belongs_to :stream

  CLASSIFICATIONS = %w[human low_suspicion suspicious probable_bot confirmed_bot unknown].freeze

  validates :username, presence: true, length: { maximum: 255 }
  validates :bot_score, presence: true, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validates :classification, presence: true, inclusion: { in: CLASSIFICATIONS }

  scope :for_stream, ->(stream_id) { where(stream_id: stream_id) }
  scope :bots, -> { where(classification: %w[probable_bot confirmed_bot]) }
  scope :humans, -> { where(classification: %w[human low_suspicion]) }
end
