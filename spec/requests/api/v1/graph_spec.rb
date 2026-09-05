# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Audience graph API" do
  it "requires auth (401 guest)" do
    get "/api/v1/graph/audience"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the graph shape for a registered user" do
    user = create(:user, tier: "free")
    token = Auth::JwtService.encode_access(user.id)

    get "/api/v1/graph/audience", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["basis"]).to eq("chat_presence")
    expect(data).to have_key("nodes")
    expect(data).to have_key("edges")
  end

  it "404s an unknown focus" do
    user = create(:user, tier: "free")
    token = Auth::JwtService.encode_access(user.id)

    get "/api/v1/graph/audience", params: { focus: "ghost" },
        headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:not_found)
  end
end
