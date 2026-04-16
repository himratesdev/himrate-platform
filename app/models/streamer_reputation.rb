# frozen_string_literal: true

# TASK-037 FR-016: Streamer Reputation — historical behavior assessment.
# 4 components: Growth Pattern, Follower Quality, Engagement Consistency, Pattern History.
# FR-022: Multiple records per channel (history, not find_or_initialize).
class StreamerReputation < ApplicationRecord
  belongs_to :channel

  validates :calculated_at, presence: true
  validates :growth_pattern_score, numericality: { in: 0..100 }, allow_nil: true
  validates :follower_quality_score, numericality: { in: 0..100 }, allow_nil: true
  validates :engagement_consistency_score, numericality: { in: 0..100 }, allow_nil: true
  validates :pattern_history_score, numericality: { in: 0..100 }, allow_nil: true

  def self.latest_for(channel_id)
    where(channel_id: channel_id).order(calculated_at: :desc).first
  end
end
