# frozen_string_literal: true

# TASK-036: Full watchlist model — user-created channel collections.
# Watchlist = bookmarks (free). Tracking = monitoring ($9.99/mo per channel).
class Watchlist < ApplicationRecord
  MAX_CHANNELS_PER_LIST = 100
  DEFAULT_NAME = "My Watchlist"

  belongs_to :user
  has_many :watchlist_channels, dependent: :destroy
  has_many :channels, through: :watchlist_channels
  has_many :watchlist_tags_notes, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }

  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  # FR-002/004: Auto-create default watchlist for user
  def self.ensure_default_for(user)
    return if user.watchlists.exists?

    user.watchlists.create!(name: DEFAULT_NAME, position: 0)
  end

  def channels_count
    watchlist_channels.size
  end

  def full?
    channels_count >= MAX_CHANNELS_PER_LIST
  end
end
