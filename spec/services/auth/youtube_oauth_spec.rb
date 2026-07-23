# frozen_string_literal: true

require "rails_helper"

RSpec.describe Auth::YoutubeOauth do
  let(:user) { create(:user) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("GOOGLE_CLIENT_ID").and_return("gcid")
    allow(ENV).to receive(:fetch).with("GOOGLE_CLIENT_SECRET").and_return("gsec")
    allow(ENV).to receive(:fetch).with("GOOGLE_REDIRECT_URI")
                                 .and_return("https://staging.himrate.com/api/v1/auth/google/callback")
  end

  describe "#authorize_url" do
    it "derives the youtube callback from the google one and requests offline yt-analytics" do
      url = described_class.new.authorize_url(state: "s1")
      expect(url).to include(CGI.escape("https://staging.himrate.com/api/v1/auth/youtube/callback"))
      expect(url).to include("yt-analytics.readonly", "access_type=offline", "prompt=consent")
    end
  end

  describe "#connect!" do
    subject(:svc) { described_class.new }

    def stub_token(refresh: "rt1")
      body = { access_token: "at1", refresh_token: refresh, expires_in: 3600 }.compact.to_json
      allow(HTTP).to receive(:timeout).and_return(http)
      allow(http).to receive(:post).and_return(double(status: double(success?: true), body: body))
    end
    let(:http) { double }

    def stub_channel(id:, ok: true)
      allow(http).to receive(:auth).and_return(http)
      allow(http).to receive(:get).and_return(
        double(status: double(success?: ok), body: { items: (id ? [ { id: id } ] : []) }.to_json)
      )
    end

    it "stores a youtube AuthProvider with the channel id + refresh token + scopes" do
      stub_token
      stub_channel(id: "UC_abc")

      provider = svc.connect!(code: "c", user: user)

      expect(provider.provider).to eq("youtube")
      expect(provider.provider_id).to eq("UC_abc")
      expect(provider.refresh_token).to eq("rt1")
      expect(provider.scopes).to include("https://www.googleapis.com/auth/yt-analytics.readonly")
    end

    it "raises (no half-connected row) when the Google account has no YouTube channel" do
      stub_token
      stub_channel(id: nil)
      expect { svc.connect!(code: "c", user: user) }.to raise_error(Auth::AuthError, /no YouTube channel/)
      expect(AuthProvider.where(user: user, provider: "youtube")).to be_empty
    end

    it "raises when a NEW connection returns no refresh token (offline polling would be dead)" do
      stub_token(refresh: nil)
      stub_channel(id: "UC_abc")
      expect { svc.connect!(code: "c", user: user) }.to raise_error(Auth::AuthError, /refresh token/)
    end

    it "raises RecordNotUnique when the channel is already linked to a DIFFERENT user (anti-hijack)" do
      other = create(:user)
      AuthProvider.create!(user: other, provider: "youtube", provider_id: "UC_taken",
                           access_token: "x", refresh_token: "y")
      stub_token
      stub_channel(id: "UC_taken")

      expect { svc.connect!(code: "c", user: user) }.to raise_error(ActiveRecord::RecordNotUnique)
      # the other user's connection is untouched
      expect(AuthProvider.find_by(provider: "youtube", provider_id: "UC_taken").user_id).to eq(other.id)
    end
  end
end
