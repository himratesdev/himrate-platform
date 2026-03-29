# frozen_string_literal: true

# TASK-025: Enhanced with validations and scopes.

class ChattersSnapshot < ApplicationRecord
  belongs_to :stream

  validates :timestamp, presence: true
  validates :unique_chatters_count, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :for_stream, ->(stream_id) { where(stream_id: stream_id) }
  scope :in_timerange, ->(from, to) { where(timestamp: from..to) }
  scope :recent, -> { order(timestamp: :desc) }
end
