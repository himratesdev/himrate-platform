# frozen_string_literal: true

# TASK-038 AR-07: Recommendation metadata in DB (not hardcoded).
# Conditions remain Ruby lambdas (see HealthScore::RecommendationRules).
# Metadata (i18n, impact, cta, enabled) — DB-editable post-launch.

class RecommendationTemplate < ApplicationRecord
  PRIORITIES = %w[critical high medium low].freeze
  COMPONENTS = %w[engagement consistency stability growth trust_index all].freeze

  validates :rule_id, presence: true, uniqueness: true,
    format: { with: /\AR-\d{2}\z/ }
  validates :component, presence: true, inclusion: { in: COMPONENTS }
  validates :priority, presence: true, inclusion: { in: PRIORITIES }
  validates :i18n_key, presence: true
  validates :display_order, presence: true, numericality: { only_integer: true }

  scope :enabled, -> { where(enabled: true) }
  scope :for_component, ->(comp) { where(component: comp) }

  def self.enabled_rule_ids
    enabled.pluck(:rule_id)
  end
end
