# frozen_string_literal: true

require "rails_helper"

RSpec.describe Subscriptions::TierRecompute do
  it "drops to free when no active subscriptions remain" do
    user = create(:user, tier: "premium")
    create(:subscription, user: user, tier: "premium", is_active: false, cancelled_at: Time.current)

    expect(described_class.call(user)).to eq("free")
    expect(user.reload.tier).to eq("free")
  end

  it "keeps the highest tier among remaining active grants" do
    user = create(:user, tier: "premium")
    create(:subscription, user: user, tier: "premium")
    create(:subscription, user: user, tier: "business", plan_type: "promo", price: 0)

    expect(described_class.call(user)).to eq("business")
    expect(user.reload.tier).to eq("business")
  end

  it "is a no-op when the tier already matches" do
    user = create(:user, tier: "premium")
    create(:subscription, user: user, tier: "premium")
    expect { described_class.call(user) }.not_to change { user.reload.updated_at }
  end
end
