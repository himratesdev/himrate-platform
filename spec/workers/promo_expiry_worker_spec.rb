# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromoExpiryWorker do
  it "closes past-due promo grants and recomputes the tier from remaining active subscriptions" do
    expired_user = create(:user, tier: "premium")
    Subscription.create!(user: expired_user, tier: "premium", plan_type: "promo", price: 0,
                         started_at: 20.days.ago, is_active: true, billing_period_end: 1.day.ago)

    keeps_user = create(:user, tier: "business")
    Subscription.create!(user: keeps_user, tier: "premium", plan_type: "promo", price: 0,
                         started_at: 20.days.ago, is_active: true, billing_period_end: 1.day.ago)
    Subscription.create!(user: keeps_user, tier: "business", plan_type: "monthly", price: 99,
                         started_at: 10.days.ago, is_active: true)

    lifetime_user = create(:user, tier: "premium")
    Subscription.create!(user: lifetime_user, tier: "premium", plan_type: "promo", price: 0,
                         started_at: 20.days.ago, is_active: true, billing_period_end: nil)

    described_class.new.perform

    expect(expired_user.reload.tier).to eq("free")
    expect(expired_user.subscriptions.last).to have_attributes(is_active: false)
    expect(expired_user.subscriptions.last.cancelled_at).to be_present

    expect(keeps_user.reload.tier).to eq("business")
    expect(lifetime_user.reload.tier).to eq("premium")
    expect(lifetime_user.subscriptions.last.is_active).to be(true)
  end
end
