# frozen_string_literal: true

require "rails_helper"

# TASK-090 OQ-4 / SRS FR-019: MaintenanceMode middleware spec.
#
# Covers:
#  1. Flag OFF → normal API endpoints respond as usual (middleware is no-op).
#  2. Flag ON  → /api/v1/* returns 503 + JSON shape (incl. error +
#     retry_after_minutes per SRS FR-019) + Retry-After header.
#  3. /api/v1/health/maintenance accessible in BOTH states (HTTP 200).
#  4. /up (Rails health check) accessible during maintenance (HTTP 200).
#  5. Locale switching via Accept-Language: en/ru produces correct message.
#  6. MAINTENANCE_MODE_UNTIL ISO 8601 parsing — until_unix + retry_after_seconds
#     reflect the configured time; retry_after_minutes = ceil(seconds / 60).
#  7. MAINTENANCE_MODE_MESSAGE / _EN / _RU env overrides beat i18n default
#     (locale-specific override wins over generic).
#  8. Non-API paths (e.g. /webhooks/*) unaffected by middleware.
RSpec.describe "MaintenanceMode middleware", type: :request do
  around do |example|
    saved = ENV.slice(
      "MAINTENANCE_MODE_ACTIVE", "MAINTENANCE_MODE_UNTIL",
      "MAINTENANCE_MODE_MESSAGE", "MAINTENANCE_MODE_MESSAGE_EN", "MAINTENANCE_MODE_MESSAGE_RU"
    )
    example.run
  ensure
    %w[MAINTENANCE_MODE_ACTIVE MAINTENANCE_MODE_UNTIL MAINTENANCE_MODE_MESSAGE
       MAINTENANCE_MODE_MESSAGE_EN MAINTENANCE_MODE_MESSAGE_RU].each do |k|
      saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k)
    end
  end

  describe "when MAINTENANCE_MODE_ACTIVE=false (or unset)" do
    before { ENV["MAINTENANCE_MODE_ACTIVE"] = "false" }

    it "does not intercept /api/v1/* — request reaches the controller" do
      # Use the maintenance health endpoint itself (no auth needed) as a smoke
      # target; we only care that the middleware passed through.
      get "/api/v1/health/maintenance"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["maintenance"]).to eq(false)
      expect(body["status"]).to eq("ok")
      expect(response.headers["Retry-After"]).to be_nil
    end
  end

  describe "when MAINTENANCE_MODE_ACTIVE=true" do
    before { ENV["MAINTENANCE_MODE_ACTIVE"] = "true" }

    it "returns 503 + SRS FR-019 JSON shape + Retry-After on /api/v1/* endpoints" do
      get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Content-Type"]).to start_with("application/json")
      expect(response.headers["Retry-After"]).to eq("60") # default when no UNTIL set
      expect(response.headers["Cache-Control"]).to eq("no-store")

      body = JSON.parse(response.body)
      # SRS FR-019 / §10A contract: extension routes on `error` (apiErrorCode);
      # Frame19 countdown reads `retry_after_minutes`.
      expect(body["maintenance"]).to eq(true)
      expect(body["error"]).to eq("MAINTENANCE_MODE")
      expect(body["message"]).to be_a(String).and(be_present)
      expect(body["retry_after_seconds"]).to eq(60)
      expect(body["retry_after_minutes"]).to eq(1)
      expect(body).to have_key("until")
      expect(body).to have_key("until_unix")
    end

    it "rounds retry_after_minutes UP from retry_after_seconds (ceil)" do
      # 90s window → 2 minutes, not 1.
      ENV["MAINTENANCE_MODE_UNTIL"] = (Time.now.utc + 90).iso8601

      get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

      body = JSON.parse(response.body)
      expect(body["retry_after_seconds"]).to be_between(85, 91)
      expect(body["retry_after_minutes"]).to eq(2)
    end

    it "still allows /api/v1/health/maintenance (HTTP 200, body mirrors the 503 contract)" do
      get "/api/v1/health/maintenance"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      body = JSON.parse(response.body)
      expect(body["maintenance"]).to eq(true)
      expect(body["error"]).to eq("MAINTENANCE_MODE")
      expect(body["message"]).to be_present
      expect(body["retry_after_seconds"]).to eq(60)
      expect(body["retry_after_minutes"]).to eq(1)
    end

    it "still allows /up (Rails native health check)" do
      get "/up"

      expect(response).to have_http_status(:ok)
    end

    it "does not affect non-API paths (e.g. /webhooks/*)" do
      # Webhooks intentionally remain reachable so external systems (Twitch
      # EventSub) don't see failed deliveries during a maintenance window;
      # they hit /webhooks/twitch which is outside /api/v1.
      post "/webhooks/twitch", headers: { "Content-Type" => "application/json" }, params: {}

      # Whatever the actual webhook controller returns (400/401/etc.), it must
      # NOT be the maintenance 503 response.
      expect(response).not_to have_http_status(:service_unavailable)
      if response.status == 503
        expect(JSON.parse(response.body)).not_to include("maintenance" => true)
      end
    end

    it "returns Russian message when Accept-Language: ru" do
      get "/api/v1/channels/123", headers: {
        "Authorization" => "Bearer x",
        "Accept-Language" => "ru-RU,ru;q=0.9"
      }

      body = JSON.parse(response.body)
      expect(body["message"]).to eq(I18n.t("api.maintenance.message", locale: :ru))
      expect(body["message"]).to include("Системные") # smoke check the literal
    end

    it "returns English message when Accept-Language: en (default)" do
      get "/api/v1/channels/123", headers: {
        "Authorization" => "Bearer x",
        "Accept-Language" => "en-US,en;q=0.9"
      }

      body = JSON.parse(response.body)
      expect(body["message"]).to eq(I18n.t("api.maintenance.message", locale: :en))
    end

    it "supports ?lang=ru query override of Accept-Language" do
      get "/api/v1/channels/123?lang=ru", headers: {
        "Authorization" => "Bearer x",
        "Accept-Language" => "en-US,en;q=0.9"
      }

      body = JSON.parse(response.body)
      expect(body["message"]).to eq(I18n.t("api.maintenance.message", locale: :ru))
    end

    context "with MAINTENANCE_MODE_UNTIL set" do
      let(:until_time) { Time.utc(2099, 1, 1, 12, 0, 0) }

      before { ENV["MAINTENANCE_MODE_UNTIL"] = until_time.iso8601 }

      it "parses ISO 8601 and exposes until / until_unix / retry_after_seconds" do
        get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

        body = JSON.parse(response.body)
        expect(body["until"]).to eq(until_time.iso8601)
        expect(body["until_unix"]).to eq(until_time.to_i)
        expect(body["retry_after_seconds"]).to be > 0
        expect(response.headers["Retry-After"]).to eq(body["retry_after_seconds"].to_s)
      end

      it "tolerates malformed UNTIL (falls back to default Retry-After, re-derives until)" do
        ENV["MAINTENANCE_MODE_UNTIL"] = "not-a-real-date"

        get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

        body = JSON.parse(response.body)
        # CR A1: until/until_unix must stay non-null even on malformed input —
        # derived from retry_after_seconds (now + 60).
        expect(body["until"]).to be_a(String)
        expect(Time.iso8601(body["until"])).to be_within(5.seconds).of(Time.now.utc + 60)
        expect(body["until_unix"]).to be_within(5).of((Time.now.utc + 60).to_i)
        expect(body["retry_after_seconds"]).to eq(60)
        expect(response).to have_http_status(:service_unavailable)
      end

      it "logs a warning on malformed UNTIL" do
        ENV["MAINTENANCE_MODE_UNTIL"] = "not-a-real-date"
        allow(Rails.logger).to receive(:warn)

        get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

        expect(Rails.logger).to have_received(:warn)
          .with(/MaintenanceMode: invalid MAINTENANCE_MODE_UNTIL=.*not ISO 8601/)
      end

      it "clamps past UNTIL to 60s and re-derives `until` to a future time (CR A1)" do
        ENV["MAINTENANCE_MODE_UNTIL"] = (Time.now.utc - 1.hour).iso8601

        get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

        body = JSON.parse(response.body)
        expect(body["retry_after_seconds"]).to eq(60)
        parsed_until = Time.iso8601(body["until"])
        expect(parsed_until).to be > Time.now.utc
        expect(parsed_until).to be_within(5.seconds).of(Time.now.utc + 60)
        expect(body["until_unix"]).to be_within(5).of((Time.now.utc + 60).to_i)
        expect(response.headers["Retry-After"]).to eq("60")
      end
    end

    context "when MAINTENANCE_MODE_UNTIL is unset" do
      it "still returns a non-null ISO 8601 `until` ≈ now + retry_after_seconds (CR A1)" do
        ENV.delete("MAINTENANCE_MODE_UNTIL")

        get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

        body = JSON.parse(response.body)
        expect(body["until"]).to be_a(String)
        expect { Time.iso8601(body["until"]) }.not_to raise_error
        expect(body["retry_after_seconds"]).to eq(60)
        expect(Time.iso8601(body["until"])).to be_within(5.seconds).of(Time.now.utc + body["retry_after_seconds"])
        expect(body["until_unix"]).to be_within(5).of((Time.now.utc + body["retry_after_seconds"]).to_i)
      end
    end

    context "path-prefix exclusion is boundary-matched (CR A2)" do
      it "intercepts /api/v1/healthx (not auto-excluded by the /api/v1/health prefix)" do
        get "/api/v1/healthx", headers: { "Authorization" => "Bearer x" }

        expect(response).to have_http_status(:service_unavailable)
        body = JSON.parse(response.body)
        expect(body["maintenance"]).to eq(true)
      end

      it "still excludes /api/v1/health/maintenance (exact prefix + '/')" do
        get "/api/v1/health/maintenance"

        expect(response).to have_http_status(:ok)
      end
    end

    context "with MAINTENANCE_MODE_MESSAGE overrides" do
      it "generic MAINTENANCE_MODE_MESSAGE beats the i18n default (any locale)" do
        ENV["MAINTENANCE_MODE_MESSAGE"] = "Custom downtime — see status.himrate.com"

        get "/api/v1/channels/123?lang=ru", headers: { "Authorization" => "Bearer x" }

        body = JSON.parse(response.body)
        expect(body["message"]).to eq("Custom downtime — see status.himrate.com")
      end

      it "locale-specific MAINTENANCE_MODE_MESSAGE_RU / _EN win over the generic override" do
        ENV["MAINTENANCE_MODE_MESSAGE"]    = "Generic downtime"
        ENV["MAINTENANCE_MODE_MESSAGE_RU"] = "Идут технические работы"
        ENV["MAINTENANCE_MODE_MESSAGE_EN"] = "Maintenance in progress"

        get "/api/v1/channels/123?lang=ru", headers: { "Authorization" => "Bearer x" }
        expect(JSON.parse(response.body)["message"]).to eq("Идут технические работы")

        get "/api/v1/channels/123?lang=en", headers: { "Authorization" => "Bearer x" }
        expect(JSON.parse(response.body)["message"]).to eq("Maintenance in progress")
      end

      it "falls back to the generic override when only one locale-specific var is set" do
        ENV["MAINTENANCE_MODE_MESSAGE"]    = "Generic downtime"
        ENV["MAINTENANCE_MODE_MESSAGE_RU"] = "Идут технические работы"

        get "/api/v1/channels/123?lang=en", headers: { "Authorization" => "Bearer x" }
        expect(JSON.parse(response.body)["message"]).to eq("Generic downtime")
      end
    end

    it "logs the blocked request at INFO with path + IP" do
      allow(Rails.logger).to receive(:info)

      get "/api/v1/channels/abc", headers: { "Authorization" => "Bearer x" }

      expect(Rails.logger).to have_received(:info).with(/MaintenanceMode: blocked path=\/api\/v1\/channels\/abc/)
    end
  end
end
