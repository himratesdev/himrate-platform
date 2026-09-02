# frozen_string_literal: true

# Email captured from the "cabinet opening soon" flag-off state (screen 71) to be notified when
# the SaaS ЛК (saas_lk_live) launches, and from the /pricing plan CTAs while checkout is not
# wired (source "pricing_interest" + plan). No email is sent yet.
#
# One row per INTEREST — (normalized email, source, plan) — not per address (CR iter-1 MF-1).
# Deduping on the address alone silently dropped every plan signal from a visitor who had already
# subscribed on screen 71, and kept only the first plan a visitor clicked. The same person asking
# about Premium and later Business is two demand facts, and this table is the only place they live
# until a PSP exists.
class NotifyRequest < ApplicationRecord
  belongs_to :user, optional: true

  SOURCES = %w[lk_launch pricing_interest].freeze
  # Canonical plan ids the /pricing CTAs post (mirrors PLAN_TITLES in landing/pricing.js).
  # nil = no plan (screen 71 launch-notify). Anything else is dropped by the controller so the
  # demand table can't be polluted through a public, unauthenticated POST.
  PLANS = %w[free premium business starter pro enterprise managed].freeze

  attribute :source, :string, default: "lk_launch"
  normalizes :email, with: ->(value) { value.to_s.strip.downcase }

  validates :email, presence: true,
                    length: { maximum: 255 },
                    format: { with: URI::MailTo::EMAIL_REGEXP },
                    uniqueness: { scope: %i[source plan], case_sensitive: false }
  validates :source, inclusion: { in: SOURCES }
  validates :plan, inclusion: { in: PLANS }, allow_nil: true

  scope :pending, -> { where(notified_at: nil) }

  # Idempotent capture: one row per (normalized email, source, plan). Re-submitting the SAME
  # interest is a no-op (keeps the first user); a different source or plan from the same address
  # records a new demand fact. Returns the persisted record.
  #
  # Race-safe on this public, unauthenticated endpoint (BUG-012 class): find_by short-circuits the
  # common sequential re-submit; a genuine concurrent duplicate loses at either the DB unique index
  # (RecordNotUnique) or the uniqueness validation seeing the just-committed row (RecordInvalid
  # :taken) — both mean "already exists", so we re-find. A real format/length failure re-raises so
  # the controller returns 422 rather than swallowing it.
  def self.capture(email:, user: nil, source: "lk_launch", plan: nil)
    normalized = email.to_s.strip.downcase
    interest = { email: normalized, source: source, plan: plan }
    find_by(**interest) || create!(**interest, user: user)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:email, :taken)

    find_by!(**interest)
  end
end
