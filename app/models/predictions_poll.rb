# frozen_string_literal: true

class PredictionsPoll < ApplicationRecord
  EVENT_TYPES = %w[prediction poll].freeze

  belongs_to :stream

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :participants_count, presence: true
  validates :timestamp, presence: true
end
