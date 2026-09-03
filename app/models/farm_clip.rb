# frozen_string_literal: true

# EPIC FARM: one Twitch clip in a farmed category's pool. Rows are upserted by
# Farm::ClipsPollerWorker; view snapshots accumulate so the selector can compute
# real view_velocity (unavailable retroactively — the PUBG test run proved it).
class FarmClip < ApplicationRecord
  has_many :view_snapshots, class_name: "FarmClipViewSnapshot", dependent: :delete_all

  validates :clip_id, presence: true, uniqueness: true
  validates :game_id, :broadcaster_twitch_id, :twitch_created_at, presence: true
end
