# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::ClipTranscripts", type: :request do
  let(:user) { create(:user, tier: "free") }
  let(:token) { Auth::JwtService.encode_access(user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let(:clip_id) { "AwkwardHelplessSalamanderSwiftRage" }

  before do
    allow(Flipper).to receive(:enabled?).with(:pundit_authorization).and_return(true)
  end

  describe "POST /api/v1/clip_transcripts/request" do
    context "cache hit (existing done transcript)" do
      let!(:cached) do
        create(:clip_transcript, :done, clip_id: clip_id)
      end

      it "returns immediate done + cache_hit=true" do
        post "/api/v1/clip_transcripts/request",
             params: { clip_id: clip_id }, headers: headers
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["status"]).to eq("done")
        expect(body["cache_hit"]).to be true
        expect(body["transcript"]).to be_present
      end
    end

    context "cache miss → enqueues worker" do
      it "returns 202 queued + job_id" do
        expect(ClipTranscriptWorker).to receive(:perform_async).with(clip_id)
        post "/api/v1/clip_transcripts/request",
             params: { clip_id: clip_id }, headers: headers
        expect(response).to have_http_status(:accepted)
        body = JSON.parse(response.body)
        expect(body["status"]).to eq("queued")
        expect(body["cache_hit"]).to be false
      end
    end

    context "Free 10/мес limit reached" do
      before do
        10.times { |n| create(:clip_transcript_request, user: user, clip_transcript: create(:clip_transcript, clip_id: "X#{n}")) }
      end

      it "returns 402 paywall + tier=free" do
        post "/api/v1/clip_transcripts/request",
             params: { clip_id: clip_id }, headers: headers
        expect(response).to have_http_status(:payment_required)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("limit_reached")
        expect(body["tier"]).to eq("free")
        expect(body["used"]).to eq(10)
      end
    end

    context "invalid clip_id" do
      it "returns 400 для clip_id containing slashes" do
        post "/api/v1/clip_transcripts/request",
             params: { clip_id: "../../etc/passwd" }, headers: headers
        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe "GET /api/v1/clip_transcripts/remaining" do
    it "returns tier=free + remaining=10 для new user" do
      get "/api/v1/clip_transcripts/remaining", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["tier"]).to eq("free")
      expect(body["remaining"]).to eq(10)
      expect(body["limit"]).to eq(10)
    end

    # BUG-PREMIUM-ACTIVE regression: a real Premium user (tier: "premium",
    # premium_active column defaults false) must read as premium/unlimited.
    context "Premium user (tier: premium)" do
      let(:user) { create(:user, tier: "premium") }

      it "returns tier=premium + remaining=unlimited" do
        get "/api/v1/clip_transcripts/remaining", headers: headers
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["tier"]).to eq("premium")
        expect(body["remaining"]).to eq("unlimited")
      end
    end
  end
end
