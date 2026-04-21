# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trends API (Phase C1)", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:user_business) { create(:user, tier: "business") }
  let(:headers_free) { auth_headers(user_free) }
  let(:headers_premium) { auth_headers(user_premium) }
  let(:headers_business) { auth_headers(user_business) }

  # Seed minimal SignalConfiguration rows needed by analysis services.
  before do
    configs = [
      [ "trends", "cache", "schema_version", 2 ],
      [ "trends", "trend", "direction_rising_slope_min", 0.1 ],
      [ "trends", "trend", "direction_declining_slope_max", -0.1 ],
      [ "trends", "trend", "confidence_high_r2", 0.7 ],
      [ "trends", "trend", "confidence_medium_r2", 0.4 ],
      [ "trends", "forecast", "min_points_for_forecast", 14 ],
      [ "trends", "forecast", "horizon_days_short", 7 ],
      [ "trends", "forecast", "horizon_days_long", 30 ],
      [ "trends", "forecast", "reliability_high_r2", 0.7 ],
      [ "trends", "forecast", "reliability_medium_r2", 0.4 ],
      [ "trends", "best_worst", "min_streams_required", 3 ],
      [ "trends", "anomaly_freq", "elevated_threshold_pct", 50 ],
      [ "trends", "anomaly_freq", "reduced_threshold_pct", -20 ],
      [ "trends", "anomaly_freq", "baseline_lookback_ratio", 1.0 ],
      [ "trends", "anomaly_freq", "min_baseline_streams", 3 ],
      [ "trends", "anomaly_freq", "min_confidence_threshold", 0.4 ],
      [ "trends", "coupling", "rolling_window_days", 30 ],
      [ "trends", "coupling", "healthy_r_min", 0.7 ],
      [ "trends", "coupling", "weakening_r_min", 0.3 ],
      [ "trends", "coupling", "min_history_days", 7 ],
      [ "trends", "discovery", "channel_age_max_days", 60 ],
      [ "trends", "discovery", "min_data_points", 7 ],
      [ "trends", "discovery", "logistic_r2_organic_min", 0.7 ],
      [ "trends", "discovery", "step_r2_burst_min", 0.9 ],
      [ "trends", "discovery", "burst_window_days_max", 3 ],
      [ "trends", "discovery", "burst_jump_min", 1000 ]
    ]
    SignalConfiguration.upsert_all(
      configs.map { |st, cat, name, val| { signal_type: st, category: cat, param_name: name, param_value: val, created_at: Time.current, updated_at: Time.current } },
      unique_by: %i[signal_type category param_name], on_duplicate: :skip
    )
  end

  shared_examples "requires authentication" do
    it "returns 401 для unauthenticated" do
      get endpoint_path
      expect(response).to have_http_status(:unauthorized)
    end
  end

  shared_examples "blocks Free user" do
    it "returns 403 для Free user (policy: view_trends_historical? = false)" do
      get endpoint_path, headers: headers_free
      expect(response).to have_http_status(:forbidden)
    end
  end

  shared_examples "grants Premium tracked access" do
    it "returns 200 для Premium с tracked channel" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/channels/:id/trends/erv" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/erv?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    context "Premium tracked + data" do
      before do
        create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
        create(:subscription, user: user_premium, tier: "premium", is_active: true)
        5.times do |i|
          create(:trends_daily_aggregate, channel: channel, date: (20 - i * 3).days.ago.to_date,
            erv_avg_percent: 70 + i * 3, ccv_avg: 500, ti_avg: 70)
        end
      end

      it "returns points with color + summary + trend + explanation" do
        get endpoint_path, headers: headers_premium

        expect(response).to have_http_status(:ok)
        data = response.parsed_body["data"]
        expect(data).to include("points", "summary", "trend", "trend_explanation")
        expect(data["points"].first).to include("date", "erv_percent", "color", "ccv_avg")
      end

      it "sets X-Data-Freshness header" do
        get endpoint_path, headers: headers_premium
        expect(response.headers["X-Data-Freshness"]).to be_present
      end
    end

    it "returns 400 для invalid period" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=5d", headers: headers_premium
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 403 business_required для Premium + 365d" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=365d", headers: headers_premium

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("business_required")
    end

    it "grants 365d доступ для Business" do
      create(:subscription, user: user_business, tier: "business", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=365d", headers: headers_business

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/channels/:id/trends/trust_index" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/trust_index?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "включает tier_changes + anomaly_markers" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data).to include("tier_changes", "anomaly_markers", "points", "trend")
    end
  end

  describe "GET /api/v1/channels/:id/trends/anomalies" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/anomalies?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "returns frequency_score + distribution + list" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data).to include("anomalies", "total", "unattributed_count", "frequency_score", "distribution")
    end
  end

  describe "GET /api/v1/channels/:id/trends/components" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/components?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "returns full component list + discovery + coupling" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data["components"]).to include("auth_ratio", "growth_rate")
      expect(data).to include("discovery_phase", "follower_ccv_coupling_timeline", "degradation_signals")
    end

    it "фильтрует по group=live_signals" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/components?period=30d&group=live_signals", headers: headers_premium

      data = response.parsed_body["data"]
      expect(data["components"]).not_to include("growth_rate")
      expect(data["components"]).to include("auth_ratio")
    end
  end

  describe "GET /api/v1/channels/:id/trends/rehabilitation" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/rehabilitation" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "returns tracker output" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data).to include("channel_id")
      # tracker output shape — rehabilitation_active key присутствует
      expect(data.keys).to include("rehabilitation_active").or include("active")
    end
  end

  describe "Streamer OAuth access (own channel)" do
    it "grants trends access to streamer через Twitch OAuth" do
      streamer = create(:user, role: "streamer", tier: "free")
      create(:auth_provider, user: streamer, provider: "twitch", provider_id: channel.twitch_id, is_broadcaster: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: auth_headers(streamer)
      expect(response).to have_http_status(:ok)
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
