# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Audience graph API" do
  # WEB-CONSOLIDATION §11.3 (2026-09-09): open to guests — the neighbours block on the public
  # channel card reads this same ego payload. Was 401.
  it "answers a guest — audience overlap is a fact about a channel" do
    get "/api/v1/graph/audience"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "basis")).to eq("chat_presence")
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

  it "denormalizes category/language from the channel's latest stream into nodes" do
    user = create(:user, tier: "free")
    token = Auth::JwtService.encode_access(user.id)
    a = create(:channel)
    b = create(:channel)
    5.times do |i| # MIN_SHARED edge between a and b
      %w[a b].each { |side| create(:cross_channel_presence, channel: side == "a" ? a : b, username: "shared_#{i}") }
    end
    create(:stream, channel: a, game_name: "Dota 2", language: "ru", started_at: 2.hours.ago)
    Rails.cache.clear

    get "/api/v1/graph/audience", params: { focus: a.login },
        headers: { "Authorization" => "Bearer #{token}" }

    node = response.parsed_body["data"]["nodes"].find { |n| n["login"] == a.login }
    expect(node["category"]).to eq("Dota 2")
    expect(node["language"]).to eq("RU")
  end

  it "404s an unknown focus" do
    user = create(:user, tier: "free")
    token = Auth::JwtService.encode_access(user.id)

    get "/api/v1/graph/audience", params: { focus: "ghost" },
        headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:not_found)
  end
end
