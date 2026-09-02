# frozen_string_literal: true

# TASK-H8 Day-0 (Soft Launch TASK-K3): promo code redemption (canonical path per
# bft/saas/payments.md §7: POST /api/v1/promocodes/redeem). Registered users only
# (PRICING v4.2 access matrix: redemption ✅ from Free registered up). Thin controller —
# validation/effects live in Promo::RedeemService; PROMO_* codes go to the wire as-is.
module Api
  module V1
    class PromocodesController < Api::BaseController
      before_action :authenticate_user!

      # POST /api/v1/promocodes/redeem  {code}
      def redeem
        authorize :promo, :redeem?
        result = Promo::RedeemService.new(user: current_user, code: params[:code]).call

        if result.ok
          # granted_tier (not the effective tier): a business user redeeming a premium code must
          # read "premium … until <date>", not "business … until <date>" — the latter implies the
          # business access lapses with this grant. `data.tier` still carries the effective tier.
          tier_name = I18n.t("promo.tiers.#{result.granted_tier}", default: result.granted_tier.to_s)
          message = if result.expires_at
            I18n.t("promo.success_until", tier: tier_name,
                                          until: I18n.l(result.expires_at.to_date))
          else
            I18n.t("promo.success_lifetime", tier: tier_name)
          end
          render json: { data: { tier: result.tier, expires_at: result.expires_at&.iso8601, message: message } }
        else
          render json: { error: { code: result.error, message: I18n.t("promo.errors.#{result.error.downcase}") } },
                 status: :unprocessable_entity
        end
      end
    end
  end
end
