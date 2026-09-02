# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Subscriptions", type: :request do
  let(:user) { create(:user, tier: "premium") }
  let(:headers) { auth_headers(user) }

  describe "GET /api/v1/subscriptions" do
    it "returns 401 for guests" do
      get "/api/v1/subscriptions"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the user's tier, subscriptions and promo redemptions (own only)" do
      sub = create(:subscription, user: user, plan_type: "promo", price: 0,
                                  billing_period_end: 10.days.from_now)
      create(:subscription) # someone else's — must not leak
      promo = PromoCode.create!(code: "HR-TESTAAAA", kind: "trial", grants_tier: "premium",
                                duration_days: 14, max_redemptions: 1)
      PromoRedemption.create!(promo_code: promo, user: user, granted_tier: "premium",
                              grant_expires_at: 14.days.from_now)

      get "/api/v1/subscriptions", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["tier"]).to eq("premium")
      expect(data["subscriptions"].map { |s| s["id"] }).to eq([ sub.id ])
      expect(data["subscriptions"].first).to include("plan_type" => "promo", "is_active" => true)
      expect(data["promo_redemptions"].first).to include("code_kind" => "trial", "granted_tier" => "premium")
    end
  end

  describe "POST /api/v1/subscriptions" do
    it "answers an honest 501 until the payment EPIC (TASK-042)" do
      post "/api/v1/subscriptions", headers: headers
      expect(response).to have_http_status(:not_implemented)
      expect(response.parsed_body.dig("error", "code")).to eq("BILLING_NOT_AVAILABLE")
      expect(response.parsed_body.dig("error", "message")).to be_present
    end
  end

  describe "DELETE /api/v1/subscriptions/:id" do
    it "cancels the user's own active subscription and recomputes the tier" do
      sub = create(:subscription, user: user, tier: "premium", plan_type: "promo", price: 0)

      delete "/api/v1/subscriptions/#{sub.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("cancelled" => true, "tier" => "free")
      expect(sub.reload).not_to be_is_active
      expect(sub.cancelled_at).to be_present
      expect(user.reload.tier).to eq("free")
    end

    it "keeps a tier still held by another live grant" do
      create(:subscription, user: user, tier: "business", plan_type: "promo", price: 0)
      sub = create(:subscription, user: user, tier: "premium", plan_type: "promo", price: 0)

      delete "/api/v1/subscriptions/#{sub.id}", headers: headers

      expect(user.reload.tier).to eq("business")
    end

    it "404s on someone else's subscription" do
      other = create(:subscription)
      delete "/api/v1/subscriptions/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      # Pins the envelope introduced in Api::BaseController (rescue_from RecordNotFound) — it now
      # shapes every bare .find across the API, so the contract belongs in a spec (CR iter-2).
      expect(response.parsed_body.dig("error", "code")).to eq("NOT_FOUND")
      expect(other.reload).to be_is_active
    end
  end

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
