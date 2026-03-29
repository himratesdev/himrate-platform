# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GQL Data API", type: :request do
  let(:user) { create(:user) }
  let(:channel) { create(:channel) }
  let(:token) { Auth::JwtService.encode_access(user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  describe "POST /api/v1/channels/:channel_id/gql_data" do
    it "accepts valid chatters_count data (TC-037)" do
      post "/api/v1/channels/#{channel.twitch_id}/gql_data",
        params: { data_type: "chatters_count", payload: { count: 1500 } }.to_json,
        headers: headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["status"]).to eq("accepted")
    end

    it "accepts valid community_tab data" do
      post "/api/v1/channels/#{channel.twitch_id}/gql_data",
        params: { data_type: "community_tab", payload: { viewers: %w[user1 user2], count: 2 } }.to_json,
        headers: headers

      expect(response).to have_http_status(:created)
    end

    it "accepts valid social_medias data" do
      post "/api/v1/channels/#{channel.twitch_id}/gql_data",
        params: { data_type: "social_medias", payload: { links: [ { name: "twitter", url: "https://x.com/test" } ] } }.to_json,
        headers: headers

      expect(response).to have_http_status(:created)
    end

    it "returns 401 without JWT (TC-038)" do
      post "/api/v1/channels/#{channel.twitch_id}/gql_data",
        params: { data_type: "chatters_count", payload: { count: 100 } }.to_json,
        headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 for invalid data_type" do
      post "/api/v1/channels/#{channel.twitch_id}/gql_data",
        params: { data_type: "invalid_type", payload: {} }.to_json,
        headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("INVALID_DATA_TYPE")
    end

    it "returns 404 for non-existent channel" do
      post "/api/v1/channels/nonexistent_id/gql_data",
        params: { data_type: "chatters_count", payload: { count: 100 } }.to_json,
        headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
