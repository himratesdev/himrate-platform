# frozen_string_literal: true

# TASK-113 (FR-009, M10): weekly «резюме недели». v1 reflection_source='template'; ML-hook 'llm'.
class PvaWeeklyReflection < ApplicationRecord
  SOURCES = %w[template llm].freeze

  belongs_to :user

  validates :user_id, presence: true
  validates :week_start, presence: true, uniqueness: { scope: :user_id }
  validates :narrative, presence: true
  validates :reflection_source, presence: true, inclusion: { in: SOURCES }
  validates :generated_at, presence: true

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :recent, ->(limit = 52) { order(week_start: :desc).limit(limit) }
end
