# frozen_string_literal: true

class Anomaly < ApplicationRecord
  ANOMALY_TYPES = %w[bot_wave viewbot_spike follow_bot raid_bot chat_bot organic_spike host_raid].freeze

  belongs_to :stream

  validates :timestamp, presence: true
  validates :anomaly_type, presence: true, inclusion: { in: ANOMALY_TYPES }
end
