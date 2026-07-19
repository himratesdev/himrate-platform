# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Brand::Compare", type: :request do
  let(:brand_user) { create(:user, :brand) }
  let!(:a) { create(:channel, login: "aaa", display_name: "A") }
  let!(:b) { create(:channel, login: "bbb", display_name: "B") }

  before do
    [ a, b ].each do |ch|
      2.times { |i| create(:trends_daily_aggregate, channel: ch, date: (i + 1).days.ago.to_date, ccv_avg: 10_000, erv_avg_percent: 70.0, ccv_peak: 14_000, streams_count: 1) }
    end
  end

  it "returns a compare payload for a brand user" do
    get "/api/v1/brand/compare", params: { channels: "aaa,bbb", prices: "140000,100000" }, headers: auth_headers(brand_user)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["window"]["days"]).to eq(30)
    expect(body["channels"].size).to eq(2)
    expect(body["channels"][0]["audience"]["real_avg_viewers"]).to eq(7_000) # 10000 × 0.70
    expect(body["channels"][0]["price"]["per_real_viewer"]).to eq(20.0)      # 140000 / 7000
    expect(body["best_in_row"]).to have_key("price_per_real_viewer")
    expect(body["deferred"]).to include("unique_reach")
  end

  it "denies a non-brand user (403)" do
    get "/api/v1/brand/compare", params: { channels: "aaa,bbb" }, headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects fewer than 2 channels (400)" do
    get "/api/v1/brand/compare", params: { channels: "aaa" }, headers: auth_headers(brand_user)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "code")).to eq("CHANNELS_REQUIRED")
  end

  it "returns 404 when a login is unknown" do
    get "/api/v1/brand/compare", params: { channels: "aaa,ghost" }, headers: auth_headers(brand_user)
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("CHANNEL_NOT_FOUND")
  end

  it "requires auth" do
    get "/api/v1/brand/compare", params: { channels: "aaa,bbb" }
    expect(response).to have_http_status(:unauthorized)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
  end
end
