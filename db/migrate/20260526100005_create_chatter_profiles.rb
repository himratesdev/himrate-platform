# frozen_string_literal: true

# TASK-251.W2b: cross-stream cache of per-chatter Twitch profile data (account age,
# followers, follows, profile views, videos, description/banner presence, last broadcast).
# Feeds BotDetection::Scorer#score_profile → revives Account Profile Scoring (signal #11),
# which was dead because BotScoringWorker hardcoded `profile: nil` ("future enhancement").
#
# Cached per-user (not per-stream) and refreshed on a staleness cadence by
# ChatterProfileRefreshWorker (off the :signals hot path), so BotScoringWorker reads the
# cache without making any GQL calls. New empty table → indexes created inline (the
# concurrent-index rule applies only to large existing tables under rolling deploy).
class CreateChatterProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :chatter_profiles, id: :uuid do |t|
      t.string :login, null: false
      t.string :twitch_user_id
      t.datetime :twitch_created_at  # account age (account_age_7d / _30d flags)
      t.integer :followers_count     # followers_zero flag
      t.integer :follows_count       # follows_zero / follows_excessive flags
      t.integer :profile_view_count  # profile_view_zero flag (often nil — Twitch deprecated)
      t.datetime :fetched_at, null: false

      t.timestamps
    end

    add_index :chatter_profiles, :login, unique: true
    add_index :chatter_profiles, :fetched_at
  end
end
