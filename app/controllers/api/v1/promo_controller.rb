# frozen_string_literal: true

# TASK-H8 Day-0 (Soft Launch TASK-K3): promo code redemption. Registered users only
# (PRICING v4.2 access matrix: redemption ✅ from Free registered up). Thin controller —
# validation/effects live in Promo::RedeemService; PROMO_* codes go to the wire as-is.
module Api
  module V1
    class PromoController < Api::BaseController
      before_action :authenticate_user!

      # POST /api/v1/promo/redeem  {code}
      def redeem
        authorize :promo, :redeem?
        result = Promo::RedeemService.new(user: current_user, code: params[:code]).call

        if result.ok
          render json: { data: { tier: result.tier, expires_at: result.expires_at&.iso8601 } }
        else
          render json: { error: { code: result.error, message: I18n.t("promo.errors.#{result.error.downcase}") } },
                 status: :unprocessable_entity
        end
      end
    end
  end
end
