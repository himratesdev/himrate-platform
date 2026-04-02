# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::TrackingRequests" do
  let(:user) { create(:user) }
  let(:headers) { auth_headers(user) }
  let(:guest_headers) { { "X-Extension-Install-Id" => SecureRandom.uuid } }

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end

  describe "POST /api/v1/channels/:channel_id/request_tracking" do
    it "creates tracking request for authenticated user" do
      post "/api/v1/channels/newstreamer/request_tracking", headers: headers

      expect(response).to have_http_status(:created)
      json = response.parsed_body
      expect(json["status"]).to eq("accepted")
      expect(json["channel_login"]).to eq("newstreamer")
      expect(TrackingRequest.count).to eq(1)
      expect(TrackingRequest.last.user_id).to eq(user.id)
    end

    it "creates tracking request for guest with install_id" do
      post "/api/v1/channels/newstreamer/request_tracking", headers: guest_headers

      expect(response).to have_http_status(:created)
      expect(TrackingRequest.last.extension_install_id).to be_present
      expect(TrackingRequest.last.user_id).to be_nil
    end

    it "returns 409 on duplicate request from same user" do
      create(:tracking_request, user: user, channel_login: "newstreamer")

      post "/api/v1/channels/newstreamer/request_tracking", headers: headers

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("ALREADY_REQUESTED")
    end

    it "normalizes channel_login to lowercase" do
      post "/api/v1/channels/NewStreamer/request_tracking", headers: headers

      expect(response).to have_http_status(:created)
      expect(TrackingRequest.last.channel_login).to eq("newstreamer")
    end

    it "allows different users to request same channel" do
      other_user = create(:user)
      create(:tracking_request, user: other_user, channel_login: "newstreamer")

      post "/api/v1/channels/newstreamer/request_tracking", headers: headers

      expect(response).to have_http_status(:created)
      expect(TrackingRequest.count).to eq(2)
    end

    it "rejects request without any identifier" do
      post "/api/v1/channels/newstreamer/request_tracking"

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
