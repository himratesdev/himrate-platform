# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users API", type: :request do
  let(:user) { create(:user, username: "testuser", email: "test@example.com", role: "viewer", tier: "free") }
  let(:token) { Auth::JwtService.encode_access(user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  describe "GET /api/v1/user/me" do
    it "returns user profile when authenticated" do
      get "/api/v1/user/me", headers: headers
      expect(response).to have_http_status(:ok)

      data = response.parsed_body["data"]
      expect(data["username"]).to eq("testuser")
      expect(data["email"]).to eq("test@example.com")
      expect(data["role"]).to eq("viewer")
      expect(data["tier"]).to eq("free")
      expect(data["tracked_channels_count"]).to eq(0)
      expect(data["is_streamer"]).to be false
    end

    it "returns 401 without auth" do
      get "/api/v1/user/me"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH /api/v1/user/me" do
    it "updates username" do
      patch "/api/v1/user/me", params: { username: "newname" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["username"]).to eq("newname")
    end
  end
end
