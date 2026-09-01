# frozen_string_literal: true

# TASK-H8 Day-0: nightly sweep closing expired promo grants. Deactivates `plan_type: "promo"`
# subscriptions past billing_period_end, then recomputes each affected user's tier from their
# REMAINING active subscriptions (highest wins, none → free) — so a promo expiry never clobbers
# a tier the user holds from another live grant/subscription.
class PromoExpiryWorker
  include Sidekiq::Worker
  sidekiq_options queue: :monitoring, retry: 3

  def perform
    expired = Subscription.where(plan_type: "promo", is_active: true)
                          .where("billing_period_end IS NOT NULL AND billing_period_end < ?", Time.current)
    user_ids = expired.distinct.pluck(:user_id)
    return if user_ids.empty?

    expired.update_all(is_active: false, cancelled_at: Time.current, updated_at: Time.current)

    User.where(id: user_ids).find_each { |user| recompute_tier!(user) }
    Rails.logger.info("PromoExpiryWorker: closed promo grants for #{user_ids.size} user(s)")
  end

  private

  def recompute_tier!(user)
    tiers = user.subscriptions.where(is_active: true).pluck(:tier)
    best = tiers.max_by { |t| Promo::RedeemService::TIER_RANK.fetch(t, 0) } || "free"
    user.update!(tier: best) if user.tier != best
  end
end
