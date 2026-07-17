# frozen_string_literal: true

# Email captured from the "cabinet opening soon" flag-off state (screen 71) to be notified when
# the SaaS ЛК (saas_lk_live) launches. Dedup by normalized (downcased) email. No email is sent yet.
class NotifyRequest < ApplicationRecord
  belongs_to :user, optional: true

  SOURCES = %w[lk_launch].freeze

  attribute :source, :string, default: "lk_launch"
  normalizes :email, with: ->(value) { value.to_s.strip.downcase }

  validates :email, presence: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP },
                    uniqueness: { case_sensitive: false }
  validates :source, inclusion: { in: SOURCES }

  scope :pending, -> { where(notified_at: nil) }

  # Idempotent capture: one row per normalized email. Re-submitting the same address is a no-op
  # (keeps the first user/source). Returns the persisted record.
  def self.capture(email:, user: nil)
    record = find_or_initialize_by(email: email.to_s.strip.downcase)
    record.user ||= user
    record.save!
    record
  end
end
