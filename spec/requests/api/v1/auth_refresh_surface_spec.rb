# frozen_string_literal: true

require "rails_helper"

# T1-060 FR-5 / EC-10: token refresh must carry the originating surface forward. Without
# this, a dashboard session refreshing its token is silently downgraded to extension and
# would never again receive SUBSCRIPTION_REQUIRED — defeating the ЛК paywall.
RSpec.describe "POST /api/v1/auth/refresh surface preservation", type: :request do
  let(:user) { create(:user) }

  it "preserves the dashboard surface across refresh" do
    refresh = Auth::JwtService.encode_refresh(user.id, surface: "dashboard")

    post "/api/v1/auth/refresh", params: { refresh_token: refresh }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(Auth::JwtService.decode(body["access_token"])[:aud]).to eq("dashboard")
    expect(Auth::JwtService.decode(body["refresh_token"])[:aud]).to eq("dashboard")
  end

  it "preserves the extension surface across refresh" do
    refresh = Auth::JwtService.encode_refresh(user.id) # extension default

    post "/api/v1/auth/refresh", params: { refresh_token: refresh }

    expect(response).to have_http_status(:ok)
    expect(Auth::JwtService.decode(response.parsed_body["access_token"])[:aud]).to eq("extension")
  end

  it "defaults to extension for a legacy refresh token minted without aud" do
    legacy = JWT.encode(
      { sub: user.id, type: "refresh", exp: 7.days.from_now.to_i, iat: Time.current.to_i },
      Auth::JwtService::SECRET, Auth::JwtService::ALGORITHM
    )

    post "/api/v1/auth/refresh", params: { refresh_token: legacy }

    expect(response).to have_http_status(:ok)
    expect(Auth::JwtService.decode(response.parsed_body["access_token"])[:aud]).to eq("extension")
  end
end
