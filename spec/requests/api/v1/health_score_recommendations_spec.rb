# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health Score Recommendations API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:headers) { auth_headers(user_premium) }

  before do
    load Rails.root.join("db/seeds/health_score.rb") unless RecommendationTemplate.exists?
    HealthScoreSeeds.run
    create(:tracked_channel, user: user_premium, channel: channel)
  end

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end

  describe "POST /api/v1/channels/:id/health_score/recommendations/:rule_id/dismiss" do
    it "returns 204 and creates DismissedRecommendation" do
      expect {
        post "/api/v1/channels/#{channel.id}/health_score/recommendations/R-01/dismiss", headers: headers
      }.to change(DismissedRecommendation, :count).by(1)

      expect(response).to have_http_status(:no_content)
      record = DismissedRecommendation.last
      expect(record.rule_id).to eq("R-01")
      expect(record.channel_id).to eq(channel.id)
      expect(record.user_id).to eq(user_premium.id)
    end

    it "is idempotent on duplicate dismiss" do
      DismissedRecommendation.create!(user: user_premium, channel: channel, rule_id: "R-01", dismissed_at: Time.current)

      expect {
        post "/api/v1/channels/#{channel.id}/health_score/recommendations/R-01/dismiss", headers: headers
      }.not_to change(DismissedRecommendation, :count)

      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 for unknown rule_id format (route constraint)" do
      post "/api/v1/channels/#{channel.id}/health_score/recommendations/INVALID/dismiss", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 400 for rule_id not in DB" do
      post "/api/v1/channels/#{channel.id}/health_score/recommendations/R-99/dismiss", headers: headers
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 401 for unauthenticated" do
      post "/api/v1/channels/#{channel.id}/health_score/recommendations/R-01/dismiss"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 for Free user (no access to HS)" do
      free_user = create(:user, tier: "free")
      free_headers = auth_headers(free_user)
      post "/api/v1/channels/#{channel.id}/health_score/recommendations/R-01/dismiss", headers: free_headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
