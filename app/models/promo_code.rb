# frozen_string_literal: true

# TASK-H8 promo code — a mintable grant of tier access. KINDS = the 6 canonical types
# (PRICING v4.2); kind is descriptive metadata for ops/analytics, while the actual effect is
# explicit per code (grants_tier + duration_days) so no semantics are hard-wired to a label.
class PromoCode < ApplicationRecord
  KINDS = %w[vip_lifetime influencer_90d friend_referral trial brand_pack_trial stream_featured].freeze
  TIERS = %w[premium business].freeze

  has_many :promo_redemptions, dependent: :restrict_with_error

  validates :code, presence: true, length: { maximum: 40 },
                   format: { with: /\A[A-Z0-9\-]+\z/, message: "only A-Z, 0-9 and dashes" }
  validates :kind, inclusion: { in: KINDS }
  validates :grants_tier, inclusion: { in: TIERS }
  validates :duration_days, numericality: { greater_than: 0 }, allow_nil: true
  validates :max_redemptions, numericality: { greater_than: 0 }, allow_nil: true

  before_validation { self.code = code.to_s.strip.upcase }

  scope :redeemable, -> { where(active: true).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def self.find_redeemable(raw)
    redeemable.find_by("UPPER(code) = ?", raw.to_s.strip.upcase)
  end

  def exhausted?
    max_redemptions.present? && redemptions_count >= max_redemptions
  end
end
