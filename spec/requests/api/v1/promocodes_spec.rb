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
      expect(data["message"]).to include("Premium") # brand plan name, never the raw enum
      expect(user.reload.tier).to eq("premium")
    end

    it "localizes the success message to the request locale (EN)" do
      PromoCode.create!(code: "HR-EN", kind: "vip_lifetime", grants_tier: "premium")

      post "/api/v1/promocodes/redeem", params: { code: "HR-EN" },
           headers: auth_headers(user).merge("Accept-Language" => "en")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "message")).to eq("Premium access activated — lifetime")
    end

    it "renders the RU date format in the success message (I18n.l path)" do
      # The only I18n.l call in the app: without config/locales/date.ru.yml :ru falls back to the
      # ActiveSupport default (%Y-%m-%d) and the RU user reads «активирован до 2026-12-01».
      PromoCode.create!(code: "HR-RU", kind: "trial", grants_tier: "premium", duration_days: 14)
      expected_date = 14.days.from_now.to_date.strftime("%d.%m.%Y") # dd.mm.yyyy — the RU contract

      post "/api/v1/promocodes/redeem", params: { code: "HR-RU" },
           headers: auth_headers(user).merge("Accept-Language" => "ru")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "message"))
        .to eq("Доступ уровня «Premium» активирован до #{expected_date}")
      # Guard the regression precisely: the ActiveSupport fallback would render ISO %Y-%m-%d.
      expect(response.parsed_body.dig("data", "message")).not_to match(/\d{4}-\d{2}-\d{2}/)
    end

    it "names the tier the CODE granted, not the effective tier (business redeeming premium)" do
      business = create(:user, tier: "business")
      PromoCode.create!(code: "HR-PREM", kind: "trial", grants_tier: "premium", duration_days: 14)

      post "/api/v1/promocodes/redeem", params: { code: "HR-PREM" }, headers: auth_headers(business)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["tier"]).to eq("business")          # effective tier is never downgraded
      expect(data["message"]).to include("Premium")   # …but the message names the grant (brand name, not the enum)
      expect(data["message"]).not_to include("business")
    end

    it "still answers the pre-rename path for tabs opened before the deploy" do
      PromoCode.create!(code: "HR-ALIAS", kind: "vip_lifetime", grants_tier: "premium")

      post "/api/v1/promo/redeem", params: { code: "HR-ALIAS" }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(user.reload.tier).to eq("premium")
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
