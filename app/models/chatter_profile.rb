# frozen_string_literal: true

# TASK-251.W2b: cross-stream cache of a chatter's Twitch profile, populated by
# ChatterProfileRefreshWorker from GQL and read by BotScoringWorker to feed
# BotDetection::Scorer#score_profile (Account Profile Scoring, signal #11).
class ChatterProfile < ApplicationRecord
  validates :login, presence: true, uniqueness: true
  validates :fetched_at, presence: true

  # Map cached columns → the symbol-keyed hash BotDetection::Scorer#score_profile reads. Only the
  # genuine bot-account traits are scored (TASK-251.W2b dropped streamer-presence flags;
  # TASK-251.20 dropped profile_view_count — Twitch deprecated profileViewCount GQL field), so only
  # those fields are stored/returned.
  def to_scorer_profile
    {
      followers_count: followers_count,
      created_at: twitch_created_at,
      follows_count: follows_count
    }
  end
end
