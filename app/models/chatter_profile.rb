# frozen_string_literal: true

# TASK-251.W2b: cross-stream cache of a chatter's Twitch profile, populated by
# ChatterProfileRefreshWorker from GQL and read by BotScoringWorker to feed
# BotDetection::Scorer#score_profile (Account Profile Scoring, signal #11).
class ChatterProfile < ApplicationRecord
  validates :login, presence: true, uniqueness: true
  validates :fetched_at, presence: true

  # Map cached columns → the symbol-keyed hash BotDetection::Scorer#score_profile expects.
  # description/banner are stored as presence booleans (the scorer only checks `.nil?`), so a
  # non-nil sentinel is returned when present and nil when absent.
  def to_scorer_profile
    {
      profile_view_count: profile_view_count,
      followers_count: followers_count,
      created_at: twitch_created_at,
      follows_count: follows_count,
      description: description_present ? "present" : nil,
      banner_image_url: banner_present ? "present" : nil,
      videos_count: videos_count,
      last_broadcast_at: last_broadcast_at
    }
  end
end
