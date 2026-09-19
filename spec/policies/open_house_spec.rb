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

  describe "no-login mode (:open_house_guest_access)" do
    after { Flipper.disable(:open_house_guest_access) }

    # A registered-only surface (the live board and search are guest-open by code since
    # WEB-CONSOLIDATION, so they can no longer tell the switch's two states apart).
    it "401s a session-less request while OFF" do
      Flipper.disable(:open_house_guest_access)
      get "/api/v1/watchlists"
      expect(response).to have_http_status(:unauthorized)
    end

    it "serves a session-less request from the shared demo account while ON" do
      Flipper.enable(:open_house_guest_access)
      get "/api/v1/watchlists"
      expect(response).to have_http_status(:ok)
      expect(User.find_by(email: User::DEMO_EMAIL)).to be_present
    end

    it "opens the PERSONAL surfaces too (that is the point of the switch)" do
      Flipper.enable(:open_house_guest_access)
      get "/api/v1/watchlists"
      expect(response).to have_http_status(:ok)
    end

    it "marks the session as demo in /lk/status so the UI can say so" do
      Flipper.enable(:open_house_guest_access)
      get "/api/v1/lk/status"
      body = response.parsed_body
      expect(body["authenticated"]).to be(true)
      expect(body["guest_access"]).to be(true)
    end

    it "grants the demo account no channel ownership" do
      Flipper.enable(:open_house_guest_access)
      demo = User.open_house_demo
      policy = ChannelPolicy.new(Auth::AuthContext.new(demo, Auth::AuthContext::DASHBOARD), channel)
      expect(policy.send(:owns_channel?, channel)).to be(false)
      expect(policy.send(:channel_tracked?, channel)).to be(false)
    end
  end
end
