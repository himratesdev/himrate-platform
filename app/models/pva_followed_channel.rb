# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 source #1 (FR-016): viewer's followed channel record (Helix-sourced).
# Per-user denormalized (avatar/color/display_name enriched по source #2 GQL ChannelShell).
class PvaFollowedChannel < ApplicationRecord
  self.table_name = "pva_followed_channels"

  belongs_to :user

  validates :twitch_channel_id, presence: true, uniqueness: { scope: :user_id }
  validates :followed_at, presence: true
end
