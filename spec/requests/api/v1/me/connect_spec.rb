# frozen_string_literal: true

require "rails_helper"

# ONBOARD-D0 (screen 11): own-channel connect status — real observation/oauth/stats.
RSpec.describe "Me connect status API" do
  def auth_headers(user)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
  end

  it "requires auth" do
    get "/api/v1/me/connect/status"
    expect(response).to have_http_status(:unauthorized)
  end

  it "reports linked:false with no twitch provider" do
    user = create(:user, tier: "free")
    get "/api/v1/me/connect/status", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "oauth", "linked")).to be(false)
  end

  it "reports real observation + stats for a linked streamer" do
    user = create(:user, tier: "free", username: "ownerlogin", is_streamer: false)
    create(:auth_provider, user: user, provider: "twitch", provider_id: "tw-777",
           scopes: %w[user:read:email])
    channel = create(:channel, twitch_id: "tw-777", login: "ownerlogin", is_monitored: true)
    stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago)
    create(:post_stream_report, stream: stream, duration_ms: 2 * 3_600_000,
           ccv_peak: 10, ccv_avg: 8, generated_at: 1.hour.ago)
    create(:trust_index_history, channel: channel, calculated_at: 2.minutes.ago)
    allow_any_instance_of(::Me::ConnectStatusQuery).to receive(:chat_active?).and_return(true)

    get "/api/v1/me/connect/status", headers: auth_headers(user)

    data = response.parsed_body["data"]
    expect(data.dig("oauth", "linked")).to be(true)
    expect(data.dig("oauth", "scopes")).to eq([ "user:read:email" ])
    expect(data.dig("observation", "tracked")).to be(false)
    expect(data.dig("observation", "is_monitored")).to be(true)
    expect(data.dig("stats", "streams_collected")).to eq(1)
    expect(data.dig("stats", "hours_live")).to eq(2.0)
    expect(data.dig("stats", "sources_active")).to eq(2) # chat + fresh TIH (no fresh ccv)
    expect(data.dig("stats", "last_sync_at")).to be_present
  end

  it "non-affiliate OWNER can enable observation of their own channel (track? identity fix)" do
    user = create(:user, tier: "free", username: "plainowner", is_streamer: false)
    create(:auth_provider, user: user, provider: "twitch", provider_id: "tw-888")
    channel = create(:channel, twitch_id: "tw-888", login: "plainowner")
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:billing_auto_subscription_creation).and_return(true)

    post "/api/v1/channels/#{channel.id}/track", headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    expect(TrackedChannel.find_by(user: user, channel: channel)&.tracking_enabled).to be(true)
  end
end
