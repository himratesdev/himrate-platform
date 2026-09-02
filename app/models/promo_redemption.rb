# frozen_string_literal: true

# One user's redemption of one promo code (unique pair). grant_expires_at nil = lifetime.
class PromoRedemption < ApplicationRecord
  belongs_to :promo_code
  belongs_to :user

  validates :granted_tier, inclusion: { in: PromoCode::TIERS }
  validates :user_id, uniqueness: { scope: :promo_code_id }
end
