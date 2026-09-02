# frozen_string_literal: true

# Access grant row. plan_type discriminates HOW the grant came to exist: "per_channel" =
# the billing-era shape (webhook / staging auto-create), "promo" = a promo-code grant
# (TASK-H8, price 0). Entitlement readers (ApplicationPolicy#channel_tracked?, WatchlistPolicy,
# screen 40) only care about is_active — use the .active scope, not raw where(is_active: true).
# One documented exception: ApplicationPolicy#channel_in_grace_period? asks for the inverse
# (is_active: false within 7 days of cancellation) and stays an explicit predicate.
class Subscription < ApplicationRecord
  PLAN_TYPES = %w[per_channel promo].freeze

  belongs_to :user
  has_many :tracked_channels, dependent: :nullify

  # allow_nil: the column arrived with TASK-H8 and was not backfilled, so pre-H8 rows carry
  # nil plan_type and must stay valid. Every live writer sets it (channels_controller#track =>
  # "per_channel", RedeemService => "promo", the visual-qa channel seeder => "per_channel").
  validates :plan_type, inclusion: { in: PLAN_TYPES }, allow_nil: true
  validates :tier, inclusion: { in: %w[free premium business] }

  scope :active, -> { where(is_active: true) }
end
