# frozen_string_literal: true

require "rails_helper"

# Free-text channel search — the capability the product was missing entirely (you could not type a
# nickname and find a channel, on any surface).
RSpec.describe "Channel search API", type: :request do
  def auth_headers(user)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
  end

  let(:user) { create(:user) }
  let!(:channel) { create(:channel, login: "dear_hellgirl", display_name: "dear_hellgirl", followers_total: 61_167) }

  it "requires auth" do
    get "/api/v1/search", params: { q: "dear" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "finds a channel by its Twitch nickname" do
    get "/api/v1/search", params: { q: "hellgirl" }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    row = response.parsed_body["data"].first
    expect(row["login"]).to eq("dear_hellgirl")
    expect(row["matched_on"]).to eq("twitch")
    expect(row["followers"]).to eq(61_167)
  end

  it "finds a channel by a linked social handle (the brand only knows the Telegram)" do
    ChannelSocialLink.create!(channel: channel, platform: "telegram",
                              handle: "DearHellGirl", url: "https://t.me/DearHellGirl")
    other = create(:channel, login: "someone_else")
    ChannelSocialLink.create!(channel: other, platform: "telegram", handle: "other", url: "https://t.me/other")

    get "/api/v1/search", params: { q: "DearHellGirl" }, headers: auth_headers(user)

    rows = response.parsed_body["data"]
    expect(rows.map { |r| r["login"] }).to eq([ "dear_hellgirl" ])
    expect(rows.first["matched_on"]).to eq("telegram")
  end

  it "accepts a pasted URL and strips it to the handle" do
    ChannelSocialLink.create!(channel: channel, platform: "telegram",
                              handle: "DearHellGirl", url: "https://t.me/DearHellGirl")

    get "/api/v1/search", params: { q: "https://t.me/DearHellGirl" }, headers: auth_headers(user)
    expect(response.parsed_body["data"].first["login"]).to eq("dear_hellgirl")
  end

  it "ranks an exact login above a partial match, then by followers" do
    create(:channel, login: "kate", followers_total: 10)
    create(:channel, login: "katerina_big", followers_total: 9_000)
    create(:channel, login: "katerina_small", followers_total: 5)

    get "/api/v1/search", params: { q: "kate" }, headers: auth_headers(user)

    expect(response.parsed_body["data"].map { |r| r["login"] })
      .to eq(%w[kate katerina_big katerina_small])
  end

  it "returns nothing for a too-short query instead of dumping the table" do
    get "/api/v1/search", params: { q: "d" }, headers: auth_headers(user)
    expect(response.parsed_body["data"]).to eq([])
  end
end
