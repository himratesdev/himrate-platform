# frozen_string_literal: true

class Channel < ApplicationRecord
  has_many :streams, dependent: :destroy
  has_many :tracked_channels, dependent: :destroy
  has_many :watchlist_channels, dependent: :destroy
  has_many :users, through: :tracked_channels
  has_many :trust_index_histories, dependent: :destroy
  has_many :health_scores, dependent: :destroy
  has_one :streamer_reputation, dependent: :destroy
  has_one :streamer_rating, dependent: :destroy
  has_one :channel_protection_config, dependent: :destroy
  has_many :trends_daily_aggregates, dependent: :destroy

  validates :twitch_id, presence: true, uniqueness: true
  validates :login, presence: true

  scope :active, -> { where(deleted_at: nil) }
  scope :monitored, -> { where(is_monitored: true) }

  # TASK-032 CR #5: channel_live? as instance method (DRY)
  def live?
    streams.where(ended_at: nil).exists?
  end
end
