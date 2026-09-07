# frozen_string_literal: true

require "rails_helper"

# OPEN-HOUSE switch (Flipper :open_house_all_features): every SIGNED-IN user is treated as top tier
# so testers can walk the product without promo codes. Guests must stay guests, and flipping the
# switch off must restore the paid gating exactly — no data is touched either way.
RSpec.describe "Open-house access switch", type: :request do
  let(:free_user) { create(:user, tier: "free") }
  let(:channel) { create(:channel) }

  def context_for(user)
    Auth::AuthContext.new(user, Auth::AuthContext::DASHBOARD)
  end

  context "when disabled (default)" do
    before { Flipper.disable(:open_house_all_features) }

    it "keeps brand tooling closed for a free user" do
      expect(BrandOverlapPolicy.new(context_for(free_user), :overlap).index?).to be(false)
      expect(free_user.brand?).to be(false)
      expect(free_user.roles).not_to include(:brand)
    end

    it "keeps the paid card layer closed" do
      expect(ChannelPolicy.new(context_for(free_user), channel).card_period_depth?).to be(false)
    end
  end

  context "when enabled" do
    before { Flipper.enable(:open_house_all_features) }
    after { Flipper.disable(:open_house_all_features) }

    it "opens brand tooling and reports the brand role so client paywalls open too" do
      expect(BrandOverlapPolicy.new(context_for(free_user), :overlap).index?).to be(true)
      expect(free_user.brand?).to be(true)
      expect(free_user.roles).to include(:brand)
    end

    it "opens the paid card layer" do
      expect(ChannelPolicy.new(context_for(free_user), channel).card_period_depth?).to be(true)
    end

    it "does NOT open anything for a guest" do
      guest = Auth::AuthContext.new(nil, Auth::AuthContext::DASHBOARD)
      expect(BrandOverlapPolicy.new(guest, :overlap).index?).to be(false)
      expect(ChannelPolicy.new(guest, channel).card_period_depth?).to be(false)
    end

    it "does not mutate the stored tier (flip it off and gating is back)" do
      expect(free_user.reload.tier).to eq("free")
      Flipper.disable(:open_house_all_features)
      expect(BrandOverlapPolicy.new(context_for(free_user), :overlap).index?).to be(false)
    end
  end

  describe "guest browse mode (:open_house_guest_access)" do
    let(:guest) { Auth::AuthContext.new(nil, Auth::AuthContext::DASHBOARD) }

    after { Flipper.disable(:open_house_guest_access) }

    it "keeps browse surfaces closed to a guest while OFF" do
      Flipper.disable(:open_house_guest_access)
      expect(DiscoverPolicy.new(guest, nil).live?).to be(false)
      expect(GraphPolicy.new(guest, :graph).audience?).to be(false)
    end

    it "opens browse surfaces to a guest while ON, without crashing on the nil user" do
      Flipper.enable(:open_house_guest_access)
      expect(DiscoverPolicy.new(guest, nil).live?).to be(true)
      expect(GraphPolicy.new(guest, :graph).audience?).to be(true)
      expect(ChannelPolicy.new(guest, channel).card_live_drill?).to be(true)
    end

    it "never grants identity-keyed rights to a guest" do
      Flipper.enable(:open_house_guest_access)
      policy = ChannelPolicy.new(guest, channel)
      expect(policy.send(:owns_channel?, channel)).to be(false)
      expect(policy.send(:channel_tracked?, channel)).to be(false)
      expect(policy.send(:streamer_on_channel?, channel)).to be(false)
    end

    it "reports guest_access in /lk/status so browse pages skip their login redirect" do
      Flipper.enable(:open_house_guest_access)
      get "/api/v1/lk/status"
      body = response.parsed_body
      expect(body["authenticated"]).to be(false)
      expect(body["guest_access"]).to be(true)
      expect(body["roles"]).to include("brand")
    end
  end
end
