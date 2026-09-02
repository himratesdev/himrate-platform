# frozen_string_literal: true

module Subscriptions
  # Recompute a user's tier from their REMAINING active subscriptions (highest wins, none → free).
  # Shared by PromoExpiryWorker (nightly close-out) and SubscriptionsController#destroy (user
  # cancel) so a cancel/expiry never clobbers a tier the user still holds from another live grant.
  class TierRecompute
    def self.call(user)
      tiers = user.subscriptions.active.pluck(:tier)
      best = tiers.max_by { |t| Promo::RedeemService::TIER_RANK.fetch(t, 0) } || "free"
      user.update!(tier: best) if user.tier != best
      best
    end
  end
end
