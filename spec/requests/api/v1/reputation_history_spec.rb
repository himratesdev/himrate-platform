# frozen_string_literal: true

require "rails_helper"

# T1-065: Reputation history/trajectory endpoint — free trust-summary (always-allow, surface-agnostic).
RSpec.describe "Reputation History API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:user_premium) { create(:user, tier: "premium") }

  # 12 completed streams with a final TIH each → full tier, computable band trajectory.
  before do
    12.times do |i|
      ended = (12 - i).hours.ago
      stream = create(:stream, channel: channel, started_at: ended - 2.hours, ended_at: ended)
      create(:trust_index_history, channel: channel, stream: stream,
                                   trust_index_score: 90, erv_percent: 91, calculated_at: ended)
    end
  end

  def path
    "/api/v1/channels/#{channel.id}/reputation/history"
  end

  # TC-11: guest (no auth) → 200 + trajectory, no paywall.
  it "returns 200 with trajectory for a guest (no auth)" do
    get path

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["current"]["band"]).to eq("impeccable")
    expect(data["real_audience_trajectory"].size).to eq(12)
    expect(data["trend"]).to be_present
    expect(data).not_to have_key("error")
  end

  # TC-12: registered free (extension surface, default aud) → 200, no paywall code.
  it "returns 200 for a registered free viewer on the extension surface" do
    get path, headers: auth_headers(user_free)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("data", "current", "tier")).to eq("full")
    expect(body).not_to have_key("error")
  end

  # TC-13: dashboard surface (aud=dashboard) → still 200 (free trust-summary, surface does not gate).
  it "returns 200 on the dashboard surface (free layer, not paywalled)" do
    token = Auth::JwtService.encode_access(user_premium.id, surface: "dashboard")
    get path, headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key("error")
  end

  # TC-14: cold-start insufficient → 200 honest-empty.
  it "returns 200 honest-empty for an insufficient (<3 streams) channel" do
    fresh = create(:channel)
    create(:stream, channel: fresh, started_at: 3.hours.ago, ended_at: 1.hour.ago)

    get "/api/v1/channels/#{fresh.id}/reputation/history"

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["current"]["band"]).to be_nil
    expect(data["current"]["tier"]).to eq("insufficient")
    expect(data["real_audience_trajectory"]).to eq([])
  end

  # TC-15: unknown channel → 404.
  it "returns 404 for a non-existent channel" do
    get "/api/v1/channels/#{SecureRandom.uuid}/reputation/history"
    expect(response).to have_http_status(:not_found)
  end

  # TC-16: ETag conditional → 304 on repeat with If-None-Match.
  it "supports conditional requests (304 with matching ETag)" do
    get path
    etag = response.headers["ETag"]
    expect(etag).to be_present

    get path, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
