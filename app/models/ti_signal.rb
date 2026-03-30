# frozen_string_literal: true

# TASK-028: 11 Live Signals per BFT §07.1.
# Each record = one signal computation for a stream at a point in time.

class TiSignal < ApplicationRecord
  self.table_name = "signals"

  SIGNAL_TYPES = %w[
    auth_ratio chatter_ccv_ratio ccv_step_function ccv_tier_clustering
    chat_behavior channel_protection_score cross_channel_presence
    known_bot_match raid_attribution ccv_chat_correlation
    account_profile_scoring
  ].freeze

  belongs_to :stream

  validates :timestamp, presence: true
  validates :value, presence: true
  validates :signal_type, presence: true, inclusion: { in: SIGNAL_TYPES }

  scope :latest_for_stream, ->(stream_id) {
    where(stream_id: stream_id)
      .select("DISTINCT ON (signal_type) *")
      .order(:signal_type, timestamp: :desc)
  }

  scope :for_type, ->(type) { where(signal_type: type) }
end
