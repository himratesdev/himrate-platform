# frozen_string_literal: true

# Access grant row. plan_type discriminates HOW the grant came to exist: "per_channel" =
# the billing-era shape (webhook / staging auto-create), "promo" = a promo-code grant
# (TASK-H8, price 0). Entitlement readers (ApplicationPolicy#channel_tracked?, screen 40)
# only care about is_active — use the .active scope, not raw where(is_active: true).
class Subscription < ApplicationRecord
  PLAN_TYPES = %w[per_channel promo].freeze

  belongs_to :user
  has_many :tracked_channels, dependent: :nullify

  # allow_nil: legacy/seeded rows (visual-qa seeder) carry no plan_type; the column is not
  # backfilled — a nil row is a valid pre-H8 grant.
  validates :plan_type, inclusion: { in: PLAN_TYPES }, allow_nil: true
  validates :tier, inclusion: { in: %w[free premium business] }

  scope :active, -> { where(is_active: true) }
end
