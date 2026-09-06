# frozen_string_literal: true

# TASK-H8 Day-0 (widened ONBOARD-D0): nightly sweep closing expired zero-price grants — promo
# redemptions AND 14-day business-intro grants (BusinessProfile#approve!). Deactivates grant
# subscriptions past billing_period_end, then recomputes each affected user's tier from their
# REMAINING active subscriptions (highest wins, none → free) — so a grant expiry never clobbers
# a tier the user holds from another live grant/subscription.
class PromoExpiryWorker
  include Sidekiq::Worker
  sidekiq_options queue: :monitoring, retry: 3

  def perform
    expired = Subscription.where(plan_type: %w[promo business_intro], is_active: true)
                          .where("billing_period_end IS NOT NULL AND billing_period_end < ?", Time.current)
    user_ids = expired.distinct.pluck(:user_id)
    return if user_ids.empty?

    expired.update_all(is_active: false, cancelled_at: Time.current, updated_at: Time.current)

    User.where(id: user_ids).find_each { |user| recompute_tier!(user) }
    Rails.logger.info("PromoExpiryWorker: closed expired grants for #{user_ids.size} user(s)")
  end

  private

  def recompute_tier!(user)
    tiers = user.subscriptions.where(is_active: true).pluck(:tier)
    best = tiers.max_by { |t| Promo::RedeemService::TIER_RANK.fetch(t, 0) } || "free"
    user.update!(tier: best) if user.tier != best
  end
end
