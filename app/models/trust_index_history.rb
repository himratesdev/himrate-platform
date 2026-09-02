# frozen_string_literal: true

# TASK-029: Trust Index Engine output record. V1-RETIRE (2026-09-02): rows are always
# engine_version='v2' (ERV = V − F̂ + band + authenticity); the v1 scalar columns
# (trust_index_score / erv_percent / classification / cold_start_status / confidence)
# are dropped.

class TrustIndexHistory < ApplicationRecord
  belongs_to :channel
  belongs_to :stream, optional: true

  validates :calculated_at, presence: true

  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
  scope :latest_for_channel, ->(channel_id) { for_channel(channel_id).order(calculated_at: :desc).first }
end
