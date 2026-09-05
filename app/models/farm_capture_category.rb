# frozen_string_literal: true

# EPIC FARM T-F1: one Twitch category the capture pool joins wholesale. `languages` is the
# Helix `language` allowlist (nil = every language); `viewer_floor` 0 = join everyone.
# Rows are seeded from db/seeds/farm_capture_categories.yml (Farm::CaptureCategorySeeder).
class FarmCaptureCategory < ApplicationRecord
  validates :game_id, presence: true, uniqueness: true
  validates :game_name, presence: true
  validates :viewer_floor, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  scope :enabled, -> { where(enabled: true) }

  # nil / [] both mean "no language filter" (Helix omits the param → all languages).
  def language_filter
    languages.presence
  end
end
