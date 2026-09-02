# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Promocodes API" do
  let(:user) { create(:user, tier: "free") }

  describe "POST /api/v1/promocodes/redeem" do
    it "requires auth (guest 401)" do
      post "/api/v1/promocodes/redeem", params: { code: "HR-X" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "redeems a valid code and reports the granted tier" do
      PromoCode.create!(code: "HR-GOOD", kind: "influencer_90d", grants_tier: "premium",
                        duration_days: 90, max_redemptions: 1)

      post "/api/v1/promocodes/redeem", params: { code: "hr-good" }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["tier"]).to eq("premium")
      expect(data["expires_at"]).to be_present
      expect(data["message"]).to include("premium")
      expect(user.reload.tier).to eq("premium")
    end

    it "localizes the success message to the request locale (EN)" do
      PromoCode.create!(code: "HR-EN", kind: "vip_lifetime", grants_tier: "premium")

      post "/api/v1/promocodes/redeem", params: { code: "HR-EN" },
           headers: auth_headers(user).merge("Accept-Language" => "en")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "message")).to eq("premium access activated — lifetime")
    end

    it "localizes PROMO_* errors to the request locale (EN)" do
      post "/api/v1/promocodes/redeem", params: { code: "NOPE" },
           headers: auth_headers(user).merge("Accept-Language" => "en")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "message"))
        .to eq("This promo code does not exist or is no longer valid")
    end

    it "returns a localized PROMO_* error for a bad code" do
      post "/api/v1/promocodes/redeem", params: { code: "NOPE" }, headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_entity)
      err = response.parsed_body["error"]
      expect(err["code"]).to eq("PROMO_INVALID")
      expect(err["message"]).to be_present
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
