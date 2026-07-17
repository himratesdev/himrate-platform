# frozen_string_literal: true

# Email captured from the "cabinet opening soon" flag-off state (screen 71) to be notified when
# the SaaS ЛК (saas_lk_live) launches. Dedup by normalized (downcased) email. No email is sent yet.
class NotifyRequest < ApplicationRecord
  belongs_to :user, optional: true

  SOURCES = %w[lk_launch].freeze

  attribute :source, :string, default: "lk_launch"
  normalizes :email, with: ->(value) { value.to_s.strip.downcase }

  validates :email, presence: true,
                    length: { maximum: 255 },
                    format: { with: URI::MailTo::EMAIL_REGEXP },
                    uniqueness: { case_sensitive: false }
  validates :source, inclusion: { in: SOURCES }

  scope :pending, -> { where(notified_at: nil) }

  # Idempotent capture: one row per normalized email. Re-submitting the same address is a no-op
  # (keeps the first user/source). Returns the persisted record.
  #
  # Race-safe on this public, unauthenticated endpoint (BUG-012 class): find_by short-circuits the
  # common sequential re-submit; a genuine concurrent duplicate loses at either the DB unique index
  # (RecordNotUnique) or the uniqueness validation seeing the just-committed row (RecordInvalid
  # :taken) — both mean "already exists", so we re-find. A real format/length failure re-raises so
  # the controller returns 422 rather than swallowing it.
  def self.capture(email:, user: nil)
    normalized = email.to_s.strip.downcase
    find_by(email: normalized) || create!(email: normalized, user: user)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:email, :taken)

    find_by!(email: normalized)
  end
end
