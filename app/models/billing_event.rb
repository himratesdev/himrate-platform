# frozen_string_literal: true

class BillingEvent < ApplicationRecord
  EVENT_TYPES = %w[
    payment_succeeded payment_failed
    subscription_created subscription_updated subscription_cancelled
    invoice_paid invoice_payment_failed
    refund charge_dispute
  ].freeze

  PROVIDERS = %w[yookassa stripe].freeze

  belongs_to :user

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :provider_event_id, presence: true, uniqueness: true
end
