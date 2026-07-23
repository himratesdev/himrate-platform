# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Auth::Youtube (connect-flow)", type: :request do
  let(:user) { create(:user) }
  let(:bearer) { { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" } }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("GOOGLE_CLIENT_ID").and_return("gcid")
    allow(ENV).to receive(:fetch).with("GOOGLE_CLIENT_SECRET").and_return("gsec")
    allow(ENV).to receive(:fetch).with("GOOGLE_REDIRECT_URI")
                                 .and_return("https://staging.himrate.com/api/v1/auth/google/callback")
  end

  describe "GET /api/v1/auth/youtube/connect" do
    it "redirects an unauthenticated user to /login" do
      get "/api/v1/auth/youtube/connect"
      expect(response).to redirect_to("/login")
    end

    it "caches a user-bound state and redirects to Google with the yt-analytics scope + offline access" do
      get "/api/v1/auth/youtube/connect", params: { return: "/app/social" }, headers: bearer

      expect(response).to have_http_status(:redirect)
      loc = response.location
      expect(loc).to start_with("https://accounts.google.com/o/oauth2/v2/auth")
      expect(loc).to include("yt-analytics.readonly")
      expect(loc).to include("access_type=offline")
      expect(loc).to include(CGI.escape("https://staging.himrate.com/api/v1/auth/youtube/callback"))

      state = Rack::Utils.parse_query(URI(loc).query)["state"]
      cached = Rails.cache.read("yt_connect:#{state}")
      expect(cached).to include(user_id: user.id, return_to: "/app/social")
    end

    it "clamps an off-site return target to the default" do
      get "/api/v1/auth/youtube/connect", params: { return: "https://evil.com" }, headers: bearer
      state = Rack::Utils.parse_query(URI(response.location).query)["state"]
      expect(Rails.cache.read("yt_connect:#{state}")[:return_to]).to eq("/app/settings")
    end
  end

  describe "GET /api/v1/auth/youtube/callback" do
    def seed_state(return_to: "/app/social")
      state = "st_#{SecureRandom.hex(4)}"
      Rails.cache.write("yt_connect:#{state}", { user_id: user.id, return_to: return_to }, expires_in: 10.minutes)
      state
    end

    it "connects the user and redirects back with ?youtube=connected (single-use state)" do
      state = seed_state
      oauth = instance_double(Auth::YoutubeOauth)
      allow(Auth::YoutubeOauth).to receive(:new).and_return(oauth)
      expect(oauth).to receive(:connect!).with(code: "code123", user: an_instance_of(User))

      get "/api/v1/auth/youtube/callback", params: { code: "code123", state: state }

      expect(response).to redirect_to("/app/social?youtube=connected")
      expect(Rails.cache.read("yt_connect:#{state}")).to be_nil # consumed
    end

    it "errors on an unknown/expired state" do
      get "/api/v1/auth/youtube/callback", params: { code: "c", state: "nope" }
      expect(response).to redirect_to("/app/settings?youtube=error")
    end

    it "errors when Google returned no code" do
      state = seed_state
      get "/api/v1/auth/youtube/callback", params: { state: state }
      expect(response).to redirect_to("/app/social?youtube=error")
    end

    it "surfaces a channel already linked to another account" do
      state = seed_state
      oauth = instance_double(Auth::YoutubeOauth)
      allow(Auth::YoutubeOauth).to receive(:new).and_return(oauth)
      allow(oauth).to receive(:connect!).and_raise(ActiveRecord::RecordNotUnique)

      get "/api/v1/auth/youtube/callback", params: { code: "c", state: state }
      expect(response).to redirect_to("/app/social?youtube=already_linked")
    end

    it "surfaces an OAuth failure as ?youtube=error" do
      state = seed_state
      oauth = instance_double(Auth::YoutubeOauth)
      allow(Auth::YoutubeOauth).to receive(:new).and_return(oauth)
      allow(oauth).to receive(:connect!).and_raise(Auth::AuthError, "boom")

      get "/api/v1/auth/youtube/callback", params: { code: "c", state: state }
      expect(response).to redirect_to("/app/social?youtube=error")
    end

    it "rejects a REPLAYED state (single-use) — second callback errors" do
      state = seed_state
      oauth = instance_double(Auth::YoutubeOauth)
      allow(Auth::YoutubeOauth).to receive(:new).and_return(oauth)
      allow(oauth).to receive(:connect!)

      get "/api/v1/auth/youtube/callback", params: { code: "c", state: state } # consumes state
      get "/api/v1/auth/youtube/callback", params: { code: "c", state: state } # replay
      expect(response).to redirect_to("/app/settings?youtube=error")
    end

    it "binds ONLY to the state's user, never a browser-supplied identity" do
      owner = user
      attacker = create(:user)
      state = "st_#{SecureRandom.hex(4)}"
      Rails.cache.write("yt_connect:#{state}", { user_id: owner.id, return_to: "/app/social" }, expires_in: 10.minutes)

      oauth = instance_double(Auth::YoutubeOauth)
      allow(Auth::YoutubeOauth).to receive(:new).and_return(oauth)
      # even when the request carries the ATTACKER's session, the connection binds to the state's owner
      expect(oauth).to receive(:connect!).with(code: "c", user: have_attributes(id: owner.id))

      get "/api/v1/auth/youtube/callback",
          params: { code: "c", state: state },
          headers: { "Authorization" => "Bearer #{Auth::JwtService.encode_access(attacker.id)}" }
    end
  end
end
