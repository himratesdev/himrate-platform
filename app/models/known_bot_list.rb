# frozen_string_literal: true

# TASK-026: Known bot entry from external database or internal detection.

class KnownBotList < ApplicationRecord
  SOURCES = %w[commanderroot twitchinsights twitchbots_info streamscharts truevio].freeze
  BOT_CATEGORIES = %w[view_bot service_bot unknown].freeze

  validates :username, presence: true, length: { maximum: 255 }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :confidence, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :bot_category, presence: true, inclusion: { in: BOT_CATEGORIES }
  validates :added_at, presence: true
  validates :username, uniqueness: { scope: :source }

  scope :for_source, ->(source) { where(source: source) }
  scope :view_bots, -> { where(bot_category: "view_bot") }
  scope :service_bots, -> { where(bot_category: "service_bot") }
  scope :active, -> { where("last_seen_at > ?", 30.days.ago) }
  scope :stale, -> { where("last_seen_at IS NULL OR last_seen_at < ?", 90.days.ago) }
end
