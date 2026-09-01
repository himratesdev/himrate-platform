# frozen_string_literal: true

# TASK-H8 Day-0: promo redemption gate — any REGISTERED user may redeem (PRICING v4.2 access
# matrix: redemption ✅ from Free registered up; guests must sign in first). Headless record
# (:promo symbol) — the effect is always scoped to current_user inside RedeemService.
class PromoPolicy < ApplicationPolicy
  def redeem?
    registered?
  end
end
