# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Lk", type: :request do
  describe "GET /api/v1/lk/status" do
    it "reports unauthenticated + OFF flag for a guest" do
      get "/api/v1/lk/status"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["authenticated"]).to be(false)
      expect(body["roles"]).to eq([])
      expect(body["email"]).to be_nil
      expect(body["saas_lk_live"]).to be(false) # HOOK_FLAG — OFF until ЛК launches
    end

    it "reports roles + email for an authenticated viewer" do
      user = create(:user)

      get "/api/v1/lk/status", headers: auth_headers(user)

      body = response.parsed_body
      expect(body["authenticated"]).to be(true)
      expect(body["roles"]).to eq([ "viewer" ])
      expect(body["email"]).to eq(user.email)
    end

    it "reflects saas_lk_live enabled for the actor" do
      user = create(:user)
      Flipper.enable_actor(:saas_lk_live, user)

      get "/api/v1/lk/status", headers: auth_headers(user)

      expect(response.parsed_body["saas_lk_live"]).to be(true)
    ensure
      Flipper.disable(:saas_lk_live)
    end
  end

  describe "POST /api/v1/lk/notify" do
    it "captures the email idempotently (case-insensitive)" do
      expect do
        post "/api/v1/lk/notify", params: { email: "Fan@Example.com" }
        post "/api/v1/lk/notify", params: { email: "fan@example.com" }
      end.to change(NotifyRequest, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["subscribed"]).to be(true)
      expect(NotifyRequest.last.email).to eq("fan@example.com")
    end

    it "associates the current user when authenticated" do
      user = create(:user)

      post "/api/v1/lk/notify", params: { email: "me@example.com" }, headers: auth_headers(user)

      expect(NotifyRequest.last.user).to eq(user)
    end

    it "rejects an invalid email" do
      post "/api/v1/lk/notify", params: { email: "not-an-email" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("INVALID_EMAIL")
    end
  end

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
