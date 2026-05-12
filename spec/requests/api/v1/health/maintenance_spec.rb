# frozen_string_literal: true

require "rails_helper"

# TASK-090 OQ-4 / SRS FR-019: GET /api/v1/health/maintenance polling endpoint.
#
# Always HTTP 200. When maintenance is OFF → {maintenance:false, status:"ok"}
# (no `error` field). When ON → mirrors the middleware 503 body exactly
# (maintenance:true, error:"MAINTENANCE_MODE", until/until_unix,
# retry_after_seconds, retry_after_minutes, message). Response is never cached
# (Cache-Control: no-store) so a CDN/proxy can't serve a stale state to the
# 30s poller.
RSpec.describe "GET /api/v1/health/maintenance", type: :request do
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

  context "when MAINTENANCE_MODE_ACTIVE is false (or unset)" do
    before { ENV["MAINTENANCE_MODE_ACTIVE"] = "false" }

    it "returns 200 with {maintenance:false, status:'ok'} and no error field" do
      get "/api/v1/health/maintenance"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      body = JSON.parse(response.body)
      expect(body).to eq("maintenance" => false, "status" => "ok")
      expect(body).not_to have_key("error")
    end
  end

  context "when MAINTENANCE_MODE_ACTIVE is true" do
    before { ENV["MAINTENANCE_MODE_ACTIVE"] = "true" }

    it "returns 200 with the full SRS FR-019 contract body" do
      get "/api/v1/health/maintenance"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      body = JSON.parse(response.body)
      expect(body["maintenance"]).to eq(true)
      expect(body["error"]).to eq("MAINTENANCE_MODE")
      expect(body["message"]).to be_a(String).and(be_present)
      expect(body["retry_after_seconds"]).to eq(60)
      expect(body["retry_after_minutes"]).to eq(1)
      expect(body).to have_key("until")
      expect(body).to have_key("until_unix")
      expect { Time.iso8601(body["until"]) }.not_to raise_error
    end

    it "exposes retry_after_minutes as ceil(retry_after_seconds / 60)" do
      ENV["MAINTENANCE_MODE_UNTIL"] = (Time.now.utc + 130).iso8601

      get "/api/v1/health/maintenance"

      body = JSON.parse(response.body)
      expect(body["retry_after_seconds"]).to be_between(125, 131)
      expect(body["retry_after_minutes"]).to eq(3)
    end

    it "localizes message via ?lang= (RU)" do
      get "/api/v1/health/maintenance?lang=ru"

      body = JSON.parse(response.body)
      expect(body["message"]).to eq(I18n.t("api.maintenance.message", locale: :ru))
    end

    it "honors the locale-specific MAINTENANCE_MODE_MESSAGE_RU override" do
      ENV["MAINTENANCE_MODE_MESSAGE_RU"] = "Идут технические работы"

      get "/api/v1/health/maintenance?lang=ru"

      expect(JSON.parse(response.body)["message"]).to eq("Идут технические работы")
    end
  end
end
