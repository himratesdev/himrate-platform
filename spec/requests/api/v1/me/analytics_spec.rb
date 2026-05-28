# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Me::Analytics", type: :request do
  let(:user) { create(:user) }

  def auth_headers(actor)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(actor.id)}" }
  end

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
  end

  describe "GET /api/v1/me/analytics/overview" do
    it "requires authentication" do
      get "/api/v1/me/analytics/overview"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the overview payload (cold-start when no data)" do
      get "/api/v1/me/analytics/overview", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "cold_start")).to be(true)
    end

    it "returns 400 for an invalid window" do
      get "/api/v1/me/analytics/overview", params: { window: "bogus" }, headers: auth_headers(user)
      expect(response).to have_http_status(:bad_request)
    end

    context "when the :pva flag is off" do
      before { allow(Flipper).to receive(:enabled?).with(:pva).and_return(false) }

      it "returns 404 (feature gated)" do
        get "/api/v1/me/analytics/overview", headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/me/analytics/engagement" do
    let(:body) do
      { events: [ { client_event_id: SecureRandom.uuid, event_type: "cheer", channel_id: "555",
                    amount: 100, occurred_at: Time.current.iso8601 } ],
        chat_activity: [ { channel_id: "555", date: "2026-05-28", message_count: 12,
                           first_seen_at: Time.current.iso8601, last_seen_at: Time.current.iso8601 } ],
        tenure: [ { channel_id: "555", months: 18, sub_tier: 2, observed_at: Time.current.iso8601 } ] }
    end

    it "requires authentication" do
      post "/api/v1/me/analytics/engagement", params: body, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "accepts the client-capture batch and reports queued counts" do
      post "/api/v1/me/analytics/engagement", params: body, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("queued", "events")).to eq(1)
      expect(response.parsed_body.dig("queued", "chat_activity")).to eq(1)
      expect(response.parsed_body.dig("queued", "tenure")).to eq(1)
    end

    context "when the :pva flag is off" do
      before { allow(Flipper).to receive(:enabled?).with(:pva).and_return(false) }

      it "returns 404 (feature gated)" do
        post "/api/v1/me/analytics/engagement", params: body, headers: auth_headers(user), as: :json
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "read endpoints (M6/M7/M9)" do
    it "communities returns 200 cold" do
      get "/api/v1/me/analytics/communities", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "communities")).to eq([])
    end

    it "engagement_log returns 200 cold" do
      get "/api/v1/me/analytics/engagement_log", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "entries")).to eq([])
    end

    it "supporter returns 200 cold" do
      get "/api/v1/me/analytics/supporter", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "supporters")).to eq([])
    end

    it "communities returns 400 for an invalid window" do
      get "/api/v1/me/analytics/communities", params: { window: "bogus" }, headers: auth_headers(user)
      expect(response).to have_http_status(:bad_request)
    end

    it "engagement_log returns 400 for an invalid type" do
      get "/api/v1/me/analytics/engagement_log", params: { type: "bogus" }, headers: auth_headers(user)
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "BE-4 insight read endpoints (M10/M11/M12)" do
    it "reflection returns 200 cold when no row" do
      get "/api/v1/me/analytics/reflection", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "reflection")).to be_nil
      expect(response.parsed_body.dig("meta", "cold_start")).to be(true)
    end

    it "reflection returns the row for ?week=YYYY-MM-DD" do
      monday = Date.new(2026, 5, 18)
      create(:pva_weekly_reflection, user: user, week_start: monday, narrative: "Hi")

      get "/api/v1/me/analytics/reflection", params: { week: monday.iso8601 }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "reflection", "narrative")).to eq("Hi")
    end

    it "reflection returns 400 for malformed ?week=" do
      get "/api/v1/me/analytics/reflection", params: { week: "not-a-date" }, headers: auth_headers(user)
      expect(response).to have_http_status(:bad_request)
    end

    it "reflection ?archive=true returns the week list" do
      create(:pva_weekly_reflection, user: user, week_start: Date.new(2026, 5, 11))
      create(:pva_weekly_reflection, user: user, week_start: Date.new(2026, 5, 18))

      get "/api/v1/me/analytics/reflection", params: { archive: true }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      weeks = response.parsed_body.dig("data", "archive").map { |w| w["week_start"] }
      expect(weeks).to eq([ "2026-05-18", "2026-05-11" ]) # DESC
    end

    it "patterns returns 200 cold when no rows" do
      get "/api/v1/me/analytics/patterns", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "patterns")).to eq([])
      expect(response.parsed_body.dig("meta", "cold_start")).to be(true)
    end

    it "cohort returns 200 cold when no row" do
      get "/api/v1/me/analytics/cohort", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "suggestions")).to eq([])
      expect(response.parsed_body.dig("meta", "cold_start")).to be(true)
    end

    context "when :pva is off" do
      before { allow(Flipper).to receive(:enabled?).with(:pva).and_return(false) }

      it "reflection/patterns/cohort all return 404" do
        %w[reflection patterns cohort].each do |endpoint|
          get "/api/v1/me/analytics/#{endpoint}", headers: auth_headers(user)
          expect(response).to have_http_status(:not_found), "expected 404 for #{endpoint}"
        end
      end
    end
  end

  describe "BE-5 M13 export endpoints" do
    it "POST /analytics/export returns 202 + job_id + poll_url, enqueues worker" do
      expect(PersonalAnalytics::ExportWorker).to receive(:perform_async).with(user.id, instance_of(String))

      post "/api/v1/me/analytics/export", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:accepted)
      job_id = response.parsed_body["job_id"]
      expect(job_id).to be_present
      expect(response.parsed_body["poll_url"]).to eq("/api/v1/me/analytics/export/#{job_id}")
    end

    it "GET /analytics/export/:id returns 404 when no payload in cache" do
      get "/api/v1/me/analytics/export/missing-job", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]).to eq("EXPORT_NOT_READY")
    end

    it "GET /analytics/export/:id returns archive when ready (owned by user)" do
      job_id = SecureRandom.uuid
      Rails.cache.write(PersonalAnalytics::ExportWorker.cache_key(job_id),
        { user: { id: user.id }, analytics: { view_rollups: [] } }.to_json)

      get "/api/v1/me/analytics/export/#{job_id}", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "id")).to eq(user.id)
    end

    it "GET /analytics/export/:id returns 404 if payload belongs to ANOTHER user (defense-in-depth)" do
      other = create(:user)
      job_id = SecureRandom.uuid
      Rails.cache.write(PersonalAnalytics::ExportWorker.cache_key(job_id),
        { user: { id: other.id }, analytics: {} }.to_json)

      get "/api/v1/me/analytics/export/#{job_id}", headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
    end

    it "POST + GET both return 404 when :pva is OFF" do
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)

      post "/api/v1/me/analytics/export", headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:not_found)

      get "/api/v1/me/analytics/export/any-id", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end
  end
end
