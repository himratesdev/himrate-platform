# frozen_string_literal: true

require "rails_helper"

# TASK-090 OQ-4: MaintenanceMode middleware spec.
#
# Covers:
#  1. Flag OFF → normal API endpoints respond as usual (middleware is no-op).
#  2. Flag ON  → /api/v1/* returns 503 + JSON shape + Retry-After header.
#  3. /api/v1/health/maintenance accessible in BOTH states (HTTP 200).
#  4. /up (Rails health check) accessible during maintenance (HTTP 200).
#  5. Locale switching via Accept-Language: en/ru produces correct message.
#  6. MAINTENANCE_MODE_UNTIL ISO 8601 parsing — until_unix + retry_after_seconds
#     reflect the configured time.
#  7. MAINTENANCE_MODE_MESSAGE env override beats i18n default.
#  8. Non-API paths (e.g. /webhooks/*) unaffected by middleware.
RSpec.describe "MaintenanceMode middleware", type: :request do
  around do |example|
    original_active = ENV["MAINTENANCE_MODE_ACTIVE"]
    original_until = ENV["MAINTENANCE_MODE_UNTIL"]
    original_message = ENV["MAINTENANCE_MODE_MESSAGE"]
    example.run
  ensure
    ENV["MAINTENANCE_MODE_ACTIVE"] = original_active
    ENV["MAINTENANCE_MODE_UNTIL"] = original_until
    ENV["MAINTENANCE_MODE_MESSAGE"] = original_message
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

    it "returns 503 + JSON shape + Retry-After on /api/v1/* endpoints" do
      get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Content-Type"]).to start_with("application/json")
      expect(response.headers["Retry-After"]).to eq("60") # default when no UNTIL set

      body = JSON.parse(response.body)
      expect(body["maintenance"]).to eq(true)
      expect(body["message"]).to be_a(String).and(be_present)
      expect(body["retry_after_seconds"]).to eq(60)
      expect(body).to have_key("until")
      expect(body).to have_key("until_unix")
    end

    it "still allows /api/v1/health/maintenance (HTTP 200, body reports maintenance)" do
      get "/api/v1/health/maintenance"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["maintenance"]).to eq(true)
      expect(body["message"]).to be_present
      expect(body["retry_after_seconds"]).to eq(60)
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

      it "tolerates malformed UNTIL (falls back to default Retry-After)" do
        ENV["MAINTENANCE_MODE_UNTIL"] = "not-a-real-date"

        get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

        body = JSON.parse(response.body)
        expect(body["until"]).to be_nil
        expect(body["until_unix"]).to be_nil
        expect(body["retry_after_seconds"]).to eq(60)
        expect(response).to have_http_status(:service_unavailable)
      end
    end

    context "with MAINTENANCE_MODE_MESSAGE override" do
      it "uses the env value instead of the i18n default" do
        ENV["MAINTENANCE_MODE_MESSAGE"] = "Custom downtime — see status.himrate.com"

        get "/api/v1/channels/123", headers: { "Authorization" => "Bearer x" }

        body = JSON.parse(response.body)
        expect(body["message"]).to eq("Custom downtime — see status.himrate.com")
      end
    end

    it "logs the blocked request at INFO with path + IP" do
      allow(Rails.logger).to receive(:info)

      get "/api/v1/channels/abc", headers: { "Authorization" => "Bearer x" }

      expect(Rails.logger).to have_received(:info).with(/MaintenanceMode: blocked path=\/api\/v1\/channels\/abc/)
    end
  end
end
