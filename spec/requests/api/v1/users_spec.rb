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
    it "updates display_name and locale" do
      patch "/api/v1/user/me", params: { display_name: "New Name", locale: "ru" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["display_name"]).to eq("New Name")
      expect(response.parsed_body["data"]["locale"]).to eq("ru")
    end

    it "returns avatar_url and display_name fields" do
      get "/api/v1/user/me", headers: headers
      data = response.parsed_body["data"]
      expect(data).to have_key("display_name")
      expect(data).to have_key("avatar_url")
      expect(data).to have_key("locale")
    end
  end
end
