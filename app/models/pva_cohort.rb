# frozen_string_literal: true

# TASK-113 (FR-011, M12 «Похожие зрители»): анонимная co-watch когорта. v1 'co_watch'; ML-hook 'embedding'.
class PvaCohort < ApplicationRecord
  self.table_name = "pva_cohort"

  METHODS = %w[co_watch embedding].freeze

  belongs_to :user

  validates :user_id, presence: true, uniqueness: true
  validates :cohort_method, presence: true, inclusion: { in: METHODS }
  validates :computed_at, presence: true

  scope :for_user, ->(user) { where(user_id: user.id) }
end
