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
      [ "trends", "trend", "min_points_for_trend", 3 ],
      [ "trends", "stability", "stable_min_score", 0.85 ],
      [ "trends", "stability", "moderate_min_score", 0.65 ],
      [ "trends", "stability", "min_streams_required", 3 ],
      [ "trends", "peer_comparison", "min_category_channels", 3 ],
      [ "trends", "peer_comparison", "cache_ttl_minutes", 15 ],
      [ "trends", "patterns", "weekday_pattern_min_days", 7 ],
      [ "trends", "patterns", "category_single_threshold_pct", 95 ],
      [ "trends", "insights", "top_n_count", 3 ],
      [ "trends", "insights", "p0_ti_delta_min_pts", 5.0 ],
      [ "trends", "insights", "p1_tier_change_recency_days", 30 ],
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

    it "CR M-2: 365d для Premium → structured 403 через Pundit pipeline" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=365d", headers: headers_premium

      expect(response).to have_http_status(:forbidden)
      body = response.parsed_body["error"]
      expect(body).to be_a(Hash)
      expect(body["code"]).to eq("TRENDS_BUSINESS_REQUIRED")
      expect(body["message"]).to be_present
      expect(body["cta"]).to include("action" => "upgrade", "label" => be_present)
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

  describe "GET /api/v1/channels/:id/trends/stability (FR-003)" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/stability?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "insufficient_data когда streams < min_streams_required" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["insufficient_data"]).to be true
      expect(data["label"]).to eq("insufficient_data")
    end

    it "computes score + label stable/moderate/volatile" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)
      5.times do |i|
        create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date,
          ti_avg: 80, ti_std: 2, streams_count: 2)
      end

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data["score"]).to be > 0.9
      expect(data["label"]).to eq("stable")
      expect(data).to include("cv", "ti_mean", "ti_std")
    end

    it "Business-only peer_comparison flag" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/stability?period=30d&include_peer_comparison=true", headers: headers_premium

      # Premium uses view_peer_comparison? → Premium premium_access_for? granted (FR-014) → 200
      expect(response).to have_http_status(:ok)
    end

    it "Free user with peer_comparison → 403" do
      get "/api/v1/channels/#{channel.id}/trends/stability?period=30d&include_peer_comparison=true", headers: headers_free
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/channels/:id/trends/comparison (FR-007)" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/comparison?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "returns insufficient_data without category history" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "insufficient_data")).to be true
    end

    it "computes peer percentiles when enough peers exist" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)
      create(:stream, channel: channel, game_name: "Just Chatting")
      4.times do |_|
        peer = create(:channel)
        create(:trends_daily_aggregate, channel: peer, date: 5.days.ago.to_date,
          categories: { "Just Chatting" => 1 }, ti_avg: 70, erv_avg_percent: 80, ti_std: 4)
      end
      create(:trends_daily_aggregate, channel: channel, date: 3.days.ago.to_date,
        categories: { "Just Chatting" => 1 }, ti_avg: 85, erv_avg_percent: 90, ti_std: 3)

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data["sample_size"]).to eq(4)
      expect(data["category"]).to eq("Just Chatting")
      expect(data).to include("percentiles", "channel_values")
    end
  end

  describe "GET /api/v1/channels/:id/trends/categories (FR-008 v2.0)" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/categories?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "returns verdict + categories breakdown" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)
      create(:trends_daily_aggregate, channel: channel, date: 2.days.ago.to_date,
        categories: { "Just Chatting" => 3 }, ti_avg: 80, erv_avg_percent: 85)

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data).to include("categories", "top_category", "verdict")
    end
  end

  describe "GET /api/v1/channels/:id/trends/patterns/weekday (FR-009 v2.0)" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/patterns/weekday?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "returns insight_ru/en когда enough days" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)
      14.times do |i|
        date = (i + 1).days.ago.to_date
        create(:trends_daily_aggregate, channel: channel, date: date,
          ti_avg: 70 + date.wday * 2, erv_avg_percent: 80, streams_count: 1)
      end

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data).to include("weekday_patterns", "insight_ru", "insight_en")
    end
  end

  describe "GET /api/v1/channels/:id/trends/insights (FR-010 v2.0)" do
    let(:endpoint_path) { "/api/v1/channels/#{channel.id}/trends/insights?period=30d" }

    include_examples "requires authentication"
    include_examples "blocks Free user"
    include_examples "grants Premium tracked access"

    it "returns insights array (flat fallback без notable changes)" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get endpoint_path, headers: headers_premium

      data = response.parsed_body["data"]
      expect(data["insights"]).to be_an(Array)
      expect(data["insights"].first).to include("priority", "message_ru", "message_en")
    end
  end

  describe "Streamer OAuth access (own channel)" do
    it "grants trends access to streamer через Twitch OAuth" do
      streamer = create(:user, role: "streamer", tier: "free")
      create(:auth_provider, user: streamer, provider: "twitch", provider_id: channel.twitch_id, is_broadcaster: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: auth_headers(streamer)
      expect(response).to have_http_status(:ok)
      # CR S-3: access_level reflects true tier (streamer), не hardcoded "premium".
      expect(response.parsed_body.dig("meta", "access_level")).to eq("streamer")
    end

    it "CR S-3: Business user видит access_level=business" do
      create(:subscription, user: user_business, tier: "business", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_business
      expect(response.parsed_body.dig("meta", "access_level")).to eq("business")
    end

    it "CR S-3: Premium tracked видит access_level=premium" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium
      expect(response.parsed_body.dig("meta", "access_level")).to eq("premium")
    end
  end

  describe "CR S-1: Anomalies pagination" do
    before do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)
      stream = create(:stream, channel: channel)
      75.times { |i| create(:anomaly, stream: stream, timestamp: (i + 1).hours.ago, confidence: 0.8) }
    end

    it "применяет default per_page=50 + paginates" do
      get "/api/v1/channels/#{channel.id}/trends/anomalies?period=30d", headers: headers_premium

      data = response.parsed_body["data"]
      expect(data["anomalies"].size).to eq(50)
      expect(data["pagination"]).to include("page" => 1, "per_page" => 50, "total_pages" => 2, "has_next" => true)
      expect(data["total"]).to eq(75)
    end

    it "support custom per_page + page" do
      get "/api/v1/channels/#{channel.id}/trends/anomalies?period=30d&per_page=10&page=2", headers: headers_premium

      data = response.parsed_body["data"]
      expect(data["anomalies"].size).to eq(10)
      expect(data["pagination"]).to include("page" => 2, "per_page" => 10)
    end

    it "caps per_page at MAX_PER_PAGE=200" do
      get "/api/v1/channels/#{channel.id}/trends/anomalies?period=30d&per_page=500", headers: headers_premium

      expect(response.parsed_body.dig("data", "pagination", "per_page")).to eq(200)
    end

    it "CR PG W-3: attributed_only filter reflected в total (SQL-level, не in-memory)" do
      # AnomalyAttribution валидирует source_is_known через AttributionSource lookup.
      # Seed канонические rows до создания attributions.
      # adapter_class_name required by model validations.
      [
        [ "raid_organic", "Trends::Attribution::RaidOrganicAdapter" ],
        [ "unattributed", "Trends::Attribution::UnattributedFallback" ]
      ].each do |src, adapter|
        AttributionSource.find_or_create_by!(source: src) do |r|
          r.enabled = true
          r.priority = 10
          r.display_label_en = src.humanize
          r.display_label_ru = src.humanize
          r.adapter_class_name = adapter
        end
      end

      # Remove 75 anomalies from before block — set up clean state: 3 unattributed + 2 attributed.
      Anomaly.delete_all
      stream = Stream.where(channel: channel).first
      3.times do |i|
        a = create(:anomaly, stream: stream, timestamp: (i + 1).hours.ago, confidence: 0.8)
        create(:anomaly_attribution, anomaly: a, source: "unattributed", confidence: 0.5)
      end
      2.times do |i|
        a = create(:anomaly, stream: stream, timestamp: (i + 4).hours.ago, confidence: 0.8)
        create(:anomaly_attribution, anomaly: a, source: "raid_organic", confidence: 0.85)
      end

      # Without filter: total=5
      get "/api/v1/channels/#{channel.id}/trends/anomalies?period=30d", headers: headers_premium
      expect(response.parsed_body.dig("data", "total")).to eq(5)

      # With attributed_only filter: total=2 (только raid_organic анонкилы)
      # Invalidate cache чтобы 2nd request не захватил cached payload первого call'а.
      Trends::Cache::Invalidator.call(channel.id)
      get "/api/v1/channels/#{channel.id}/trends/anomalies?period=30d&attributed_only=true", headers: headers_premium
      expect(response.parsed_body.dig("data", "total")).to eq(2)
      expect(response.parsed_body.dig("data", "anomalies").size).to eq(2)
    end
  end

  describe "CR N-4: cache hit integration" do
    before do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)
      5.times { |i| create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date, erv_avg_percent: 75, ti_avg: 70, ccv_avg: 500) }
    end

    it "2-я идентичный запрос не инвокает endpoint service" do
      allow(Trends::Api::ErvEndpointService).to receive(:new).and_call_original

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium
      expect(response).to have_http_status(:ok)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium
      expect(response).to have_http_status(:ok)

      # 2nd call = cache hit, service не вызывается второй раз.
      expect(Trends::Api::ErvEndpointService).to have_received(:new).once
    end

    it "cache invalidated после Invalidator bumps epoch" do
      allow(Trends::Api::ErvEndpointService).to receive(:new).and_call_original

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium

      # Simulate post-stream cache invalidation
      Trends::Cache::Invalidator.call(channel.id)

      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium

      # Epoch bumped → new key → service вызван снова.
      expect(Trends::Api::ErvEndpointService).to have_received(:new).twice
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
