# frozen_string_literal: true

# TASK-036 FR-018: Join table between watchlists and channels.
# Replaces channels_list jsonb for proper FK, unique constraint, position ordering.
class WatchlistChannel < ApplicationRecord
  belongs_to :watchlist
  belongs_to :channel

  validates :channel_id, uniqueness: { scope: :watchlist_id, message: "already in this watchlist" }
  validates :added_at, presence: true

  scope :ordered, -> { order(position: :asc, added_at: :desc) }
end
