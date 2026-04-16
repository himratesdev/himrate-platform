# frozen_string_literal: true

# TASK-038 AR-10: Health Score categories — DB-driven (not hardcoded).
# Admin-editable post-launch. Alias table for Twitch game_name variants.

class HealthScoreCategory < ApplicationRecord
  has_many :aliases, class_name: "HealthScoreCategoryAlias", dependent: :destroy

  validates :key, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9_]+\z/, message: "must be lowercase_snake_case" }
  validates :display_name, presence: true
  validate :single_default

  def self.default_category
    where(is_default: true).first
  end

  def self.default!
    default_category || raise("Default HealthScoreCategory not seeded")
  end

  private

  def single_default
    return unless is_default

    existing = self.class.where(is_default: true).where.not(id: id)
    errors.add(:is_default, "only one category can be default") if existing.exists?
  end
end
