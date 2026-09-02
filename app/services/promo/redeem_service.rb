# frozen_string_literal: true

module Promo
  # TASK-H8 Day-0: redeem a promo code for the signed-in user. One transaction:
  # validate → record the redemption (unique per user+code, counter-capped) → open a
  # `plan_type: "promo"` Subscription row (the billing-era shape — grace/tracking logic
  # already reads subscriptions) → lift user.tier if the grant outranks the current tier.
  # Returns Result(ok:, error:, tier:, granted_tier:, expires_at:) — `tier` is the user's
  # EFFECTIVE tier after the lift (wire contract), `granted_tier` is what this code actually
  # granted. They differ when a business user redeems a premium code: the message must say
  # "premium … until <date>", otherwise it implies the business access expires with the grant
  # (it does not — PromoExpiryWorker recomputes from the remaining grants). Error codes are
  # wire-ready PROMO_*.
  class RedeemService
    # Tier ordering lives on the model (Subscription::TIER_RANK) — shared with
    # Subscriptions::TierRecompute. Kept as a local alias so existing callers/specs keep working.
    TIER_RANK = Subscription::TIER_RANK

    Result = Data.define(:ok, :error, :tier, :granted_tier, :expires_at) do
      def self.failure(code) = new(ok: false, error: code, tier: nil, granted_tier: nil, expires_at: nil)
    end

    def initialize(user:, code:)
      @user = user
      @raw_code = code
    end

    def call
      promo = PromoCode.find_redeemable(@raw_code)
      return Result.failure("PROMO_INVALID") unless promo

      ActiveRecord::Base.transaction do
        promo.lock!
        # Already-redeemed wins over exhausted: the user who holds the grant should hear
        # "you already have it", not "the code ran out" (which reads as losing access).
        if PromoRedemption.exists?(promo_code: promo, user: @user)
          return Result.failure("PROMO_ALREADY_REDEEMED")
        end
        return Result.failure("PROMO_EXHAUSTED") if promo.exhausted?

        expires_at = promo.duration_days&.days&.from_now
        PromoRedemption.create!(promo_code: promo, user: @user,
                                granted_tier: promo.grants_tier, grant_expires_at: expires_at)
        promo.increment!(:redemptions_count)

        Subscription.create!(user: @user, tier: promo.grants_tier, plan_type: "promo",
                             price: 0, started_at: Time.current, is_active: true,
                             billing_period_end: expires_at)

        lift_tier!(promo.grants_tier)

        Result.new(ok: true, error: nil, tier: @user.tier,
                   granted_tier: promo.grants_tier, expires_at: expires_at)
      end
    end

    private

    # Never downgrade: a business user redeeming a premium code keeps business.
    def lift_tier!(granted)
      return if TIER_RANK.fetch(@user.tier, 0) >= TIER_RANK.fetch(granted)

      @user.update!(tier: granted)
    end
  end
end
