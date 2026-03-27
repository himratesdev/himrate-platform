# frozen_string_literal: true

class TiSignal < ApplicationRecord
  self.table_name = "signals"

  SIGNAL_TYPES = %w[
    account_age follower_ratio chat_engagement auth_ratio viewer_retention
    channel_protection_score stream_consistency gift_sub_ratio emote_usage
    concurrent_viewer_pattern follow_pattern
  ].freeze

  belongs_to :stream

  validates :timestamp, presence: true
  validates :value, presence: true
  validates :signal_type, presence: true, inclusion: { in: SIGNAL_TYPES }
end
