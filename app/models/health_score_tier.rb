# frozen_string_literal: true

# TASK-038 AR-08: HS tier palette in DB (not hardcoded).
# 5 tiers seeded. Design team can update colors/labels without deploy.

class HealthScoreTier < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :min_score, :max_score, :display_order, presence: true, numericality: { only_integer: true }
  validates :color_name, :bg_hex, :text_hex, :i18n_key, presence: true
  validates :bg_hex, :text_hex, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validate :range_valid

  scope :ordered, -> { order(:display_order) }

  def self.for_score(score)
    return nil if score.nil?

    rounded = score.round.to_i.clamp(0, 100)
    ordered.find { |t| rounded.between?(t.min_score, t.max_score) }
  end

  private

  def range_valid
    return unless min_score && max_score

    errors.add(:max_score, "must be >= min_score") if max_score < min_score
  end
end
