# frozen_string_literal: true

module Api
  module V1
    # P5 (screen 40 «Подписка и биллинг»): the read/cancel half of subscriptions. Today the only
    # writer is promo redemption (plan_type: "promo", TASK-H8) — checkout stays a payment-provider
    # EPIC (TASK-042), so #create answers an honest 501 instead of a stub 200.
    class SubscriptionsController < Api::BaseController
      before_action :authenticate_user!

      # GET /api/v1/subscriptions — the signed-in user's own grants (screen 40 data source).
      def index
        authorize Subscription
        subs = current_user.subscriptions.order(started_at: :desc)
        redemptions = current_user.promo_redemptions.includes(:promo_code).order(created_at: :desc)
        render json: {
          data: {
            tier: current_user.tier,
            subscriptions: subs.map { |s| subscription_json(s) },
            promo_redemptions: redemptions.map { |r| redemption_json(r) }
          }
        }
      end

      # POST /api/v1/subscriptions — no payment provider is wired (TASK-042). Honest 501.
      def create
        authorize Subscription
        render json: {
          error: { code: "BILLING_NOT_AVAILABLE", message: I18n.t("api.errors.billing_not_available") }
        }, status: :not_implemented
      end

      # DELETE /api/v1/subscriptions/:id — cancel OWN active subscription; tier recomputed from
      # the remaining active grants (never clobbers one held elsewhere).
      def destroy
        subscription = current_user.subscriptions.active.find(params[:id])
        authorize subscription
        subscription.update!(is_active: false, cancelled_at: Time.current)
        tier = Subscriptions::TierRecompute.call(current_user)
        render json: { data: { cancelled: true, tier: tier } }
      end

      private

      def subscription_json(s)
        {
          id: s.id, tier: s.tier, plan_type: s.plan_type, price: s.price,
          started_at: s.started_at&.iso8601, billing_period_end: s.billing_period_end&.iso8601,
          is_active: s.is_active, cancelled_at: s.cancelled_at&.iso8601
        }
      end

      def redemption_json(r)
        {
          code_kind: r.promo_code.kind, granted_tier: r.granted_tier,
          grant_expires_at: r.grant_expires_at&.iso8601, redeemed_at: r.created_at.iso8601
        }
      end
    end
  end
end
