# frozen_string_literal: true

# ONBOARD-D0 (screen 72): a brand/agency business-account application. One per user.
# Lifecycle: draft (form autosave) → pending (submit, full validation) → approved/rejected
# (PO decision — `BusinessProfile.find(...).approve!` / `.reject!("note")` via rails runner
# until the admin panel, TASK-150.8). approve! grants a 14-day business intro Subscription
# so the verified brand can use the brand surfaces immediately; the grant is closed by the
# widened PromoExpiryWorker sweep.
class BusinessProfile < ApplicationRecord
  ORG_TYPES = %w[ooo ip self_employed].freeze
  STATUSES = %w[draft pending approved rejected].freeze
  INTRO_DAYS = 14

  belongs_to :user

  normalizes :company_name, :website, :sphere, with: ->(v) { v.to_s.strip.presence }
  normalizes :inn, with: ->(v) { v.to_s.gsub(/\D/, "").presence }

  validates :org_type, inclusion: { in: ORG_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :company_name, length: { maximum: 160 }, allow_nil: true
  validates :website, length: { maximum: 200 }, allow_nil: true
  validates :sphere, length: { maximum: 80 }, allow_nil: true
  # RU tax IDs: ООО = 10 digits, ИП/самозанятый = 12. Format-only (no checksum — the PO
  # verifies the application by hand; a checksum would reject nothing a human review misses).
  validates :inn, format: { with: /\A\d{10}\z/, message: :inn_ooo }, allow_nil: true, if: -> { org_type == "ooo" }
  validates :inn, format: { with: /\A\d{12}\z/, message: :inn_ip }, allow_nil: true, if: -> { org_type != "ooo" }

  with_options if: -> { status == "pending" } do
    validates :company_name, :inn, :sphere, presence: true
    validates :authority_confirmed, acceptance: { accept: true }
  end

  def approve!
    transaction do
      update!(status: "approved", review_note: nil)
      Subscription.create!(user: user, tier: "business", plan_type: "business_intro",
                           price: 0, started_at: Time.current, is_active: true,
                           billing_period_end: INTRO_DAYS.days.from_now)
      # Never downgrade (same rule as Promo::RedeemService#lift_tier!).
      rank = Promo::RedeemService::TIER_RANK
      user.update!(tier: "business") if rank.fetch(user.tier, 0) < rank.fetch("business")
    end
  end

  def reject!(note)
    update!(status: "rejected", review_note: note)
  end
end
