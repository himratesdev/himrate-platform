# frozen_string_literal: true

# TASK-038 FR-021: Dismissed recommendations — permanent storage (no TTL).
# Uniqueness scope: (user, channel, rule_id). Dismissed recs excluded from RecommendationService output.

class DismissedRecommendation < ApplicationRecord
  belongs_to :user
  belongs_to :channel

  validates :rule_id, presence: true,
    format: { with: /\AR-\d{2,}\z/, message: "must be in format R-NN (2+ digits)" }
  validates :rule_id, uniqueness: { scope: %i[user_id channel_id] }
  validates :dismissed_at, presence: true
  validate :rule_id_must_exist

  before_validation :set_dismissed_at, on: :create

  private

  def set_dismissed_at
    self.dismissed_at ||= Time.current
  end

  def rule_id_must_exist
    return if rule_id.blank?
    return if RecommendationTemplate.exists?(rule_id: rule_id)

    errors.add(:rule_id, "does not reference an existing RecommendationTemplate")
  end
end
