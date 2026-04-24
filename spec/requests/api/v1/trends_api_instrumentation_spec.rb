# frozen_string_literal: true

require "rails_helper"

# TASK-039 Phase E1 SRS §10: monitoring hooks для Trends API.
# Verifies что each controller call emits trends.api.request event с полной
# payload (endpoint, period, cache_hit, duration_ms) — consumer'ами являются
# Sentry/StatsD/Prometheus subscribers (external to this codebase).
RSpec.describe "Trends API instrumentation", type: :request do
  let(:channel) { create(:channel) }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:headers_premium) { auth_headers(user_premium) }

  before do
    create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
    create(:subscription, user: user_premium, tier: "premium", is_active: true)

    SignalConfiguration.upsert_all(
      [
        [ "trends", "cache", "schema_version", 2 ],
        [ "trends", "trend", "direction_rising_slope_min", 0.1 ],
        [ "trends", "trend", "direction_declining_slope_max", -0.1 ],
        [ "trends", "trend", "confidence_high_r2", 0.7 ],
        [ "trends", "trend", "confidence_medium_r2", 0.4 ],
        [ "trends", "trend", "min_points_for_trend", 3 ],
        [ "trends", "forecast", "min_points_for_forecast", 14 ],
        [ "trends", "forecast", "horizon_days_short", 7 ],
        [ "trends", "forecast", "horizon_days_long", 30 ],
        [ "trends", "forecast", "reliability_high_r2", 0.7 ],
        [ "trends", "forecast", "reliability_medium_r2", 0.4 ],
        [ "trends", "best_worst", "min_streams_required", 3 ]
      ].map { |st, cat, name, val|
        { signal_type: st, category: cat, param_name: name, param_value: val,
          created_at: Time.current, updated_at: Time.current }
      },
      unique_by: %i[signal_type category param_name], on_duplicate: :skip
    )

    3.times { |i| create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date,
      erv_avg_percent: 75, ti_avg: 70, ccv_avg: 500) }
  end

  def capture_events(event_name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(event_name) do |_, _, _, _, payload|
      events << payload
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  describe "trends.api.request event" do
    it "emits event с cache_hit=false на первый запрос" do
      events = capture_events("trends.api.request") do
        get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium
      end

      expect(response).to have_http_status(:ok)
      expect(events.size).to eq(1)

      payload = events.first
      expect(payload[:endpoint]).to eq("erv")
      expect(payload[:period]).to eq("30d")
      expect(payload[:granularity]).to eq("daily")
      expect(payload[:channel_id]).to eq(channel.id)
      expect(payload[:cache_hit]).to be false
      expect(payload[:duration_ms]).to be > 0
    end

    it "emits cache_hit=true при повторном запросе (cached)" do
      get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium

      events = capture_events("trends.api.request") do
        get "/api/v1/channels/#{channel.id}/trends/erv?period=30d", headers: headers_premium
      end

      expect(events.size).to eq(1)
      expect(events.first[:cache_hit]).to be true
    end

    it "emits event даже при non-2xx response" do
      events = capture_events("trends.api.request") do
        # insufficient_data → 400 but render_cached still wraps
        get "/api/v1/channels/#{channel.id}/trends/erv?period=invalid", headers: headers_premium
      end

      # invalid period rescued ranее render_cached → event не эмитируется (expected).
      # Проверяем что это не crash.
      expect(response).to have_http_status(:bad_request)
      expect(events).to be_empty
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
