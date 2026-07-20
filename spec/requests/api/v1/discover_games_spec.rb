# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Discover games", type: :request do
  let(:user) { create(:user) }
  let(:headers) { { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" } }

  before do
    # Rails.cache persists across examples — isolate the shared grow keys.
    Rails.cache.delete(Grow::OpportunitiesRefreshWorker::CACHE_KEY)
    Rails.cache.delete(Grow::OpportunitiesRefreshWorker::PENDING_KEY)
  end

  describe "GET /api/v1/discover/games" do
    it "requires auth" do
      get "/api/v1/discover/games"
      expect(response).to have_http_status(:unauthorized)
    end

    it "enqueues one warm-up on a cold cache and reports pending (no enqueue storm)" do
      expect(Grow::OpportunitiesRefreshWorker).to receive(:perform_async).once
      get "/api/v1/discover/games", headers: headers
      expect(response.parsed_body.dig("data", "status")).to eq("pending")
      # second hit within the pending window must NOT enqueue again
      get "/api/v1/discover/games", headers: headers
      expect(response.parsed_body.dig("data", "status")).to eq("pending")
    end

    it "serves the ranked cached list when warm" do
      Rails.cache.write(Grow::OpportunitiesRefreshWorker::CACHE_KEY,
                        { "generated_at" => "2026-07-21T10:00:00Z",
                          "games" => [ { "name" => "NicheGem", "growth_score" => 0.8, "live_streamers" => 9 } ] })
      get "/api/v1/discover/games", headers: headers
      data = response.parsed_body["data"]
      expect(data["status"]).to eq("ready")
      expect(data["games"].first["name"]).to eq("NicheGem")
    end
  end
end
