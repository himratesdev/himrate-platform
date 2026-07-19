# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Brand::StreamerSearch", type: :request do
  let(:brand_user) { create(:user, :brand) }

  before do
    %w[alpha beta].each_with_index do |login, i|
      ch = create(:channel, login: login)
      create(:stream, channel: ch, game_name: "Dota 2", language: "ru", started_at: 1.hour.ago)
      3.times { |d| create(:trends_daily_aggregate, channel: ch, date: (d + 1).days.ago.to_date, ccv_avg: (i + 1) * 10_000, erv_avg_percent: 80.0, ti_avg: 85.0, classification_at_end: "trusted", categories: { "Dota 2" => 1 }, streams_count: 1) }
    end
  end

  it "returns a ranked search for a brand user" do
    get "/api/v1/brand/streamers/search", params: { sort: "real_avg" }, headers: auth_headers(brand_user)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["results"].size).to eq(2)
    expect(body["results"][0]["real_avg_viewers"]).to be >= body["results"][1]["real_avg_viewers"] # sorted
    expect(body["results"][0]["real_avg_viewers"]).to be < body["results"][0]["shown_avg_viewers"]
    expect(body["total"]).to eq(2)
    expect(body["results"][0]["classification_label"]).to be_present
    expect(body["deferred"]).to include("band_filter")
  end

  it "applies a min_real filter" do
    get "/api/v1/brand/streamers/search", params: { min_real: "12000" }, headers: auth_headers(brand_user)
    expect(response).to have_http_status(:ok)
    # beta = 16000 real, alpha = 8000 real → only beta
    expect(response.parsed_body["results"].map { |r| r["login"] }).to eq(%w[beta])
  end

  it "denies a non-brand user (403)" do
    get "/api/v1/brand/streamers/search", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
  end

  it "requires auth" do
    get "/api/v1/brand/streamers/search"
    expect(response).to have_http_status(:unauthorized)
  end

  it "does not shadow the streamer card route (search != :login)" do
    get "/api/v1/brand/streamers/search", headers: auth_headers(brand_user)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to have_key("results") # search shape, not a card 404
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
  end
end
