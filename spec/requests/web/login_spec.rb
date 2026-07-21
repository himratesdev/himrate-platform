# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard web login", type: :request do
  describe "login page" do
    it "renders the faithful login markup with the wiring bundle (public, no auth)" do
      get "/login"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-pencil-name="OAuth Twitch"')
      expect(response.body).to include("landing/login")
    end
  end

  describe "GET /auth/web/twitch" do
    it "302-redirects the browser to the Twitch authorize URL and caches web-flagged state" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("TWITCH_REDIRECT_URI").and_return("https://staging.himrate.com/api/v1/auth/twitch/callback")
      allow(Auth::TwitchOauth).to receive(:new).and_return(
        instance_double(Auth::TwitchOauth, authorize_url: { redirect_url: "https://id.twitch.tv/oauth2/authorize?state=abc", code_verifier: "v", state: "abc" })
      )
      get "/auth/web/twitch"
      expect(response).to have_http_status(:redirect)
      expect(response.location).to start_with("https://id.twitch.tv/oauth2/authorize")
      # web login must land INSIDE the dashboard after callback, not bounce back to /login
      expect(Rails.cache.read("pkce:abc")).to include(web: true, web_redirect: "/app/home")
    end
  end

  describe "web OAuth callback → cookie session" do
    it "sets an httpOnly session cookie that authenticates subsequent API requests" do
      user = create(:user, email: "web@himrate.test")
      allow(Auth::TwitchOauth).to receive(:new).and_return(instance_double(Auth::TwitchOauth, callback: user))
      Rails.cache.write("pkce:st8", { code_verifier: "v", redirect_uri: "https://cb", web: true, web_redirect: "/app/home" }, expires_in: 10.minutes)

      get "/api/v1/auth/twitch/callback", params: { code: "c", state: "st8" }
      expect(response).to have_http_status(:redirect)
      expect(response.location).to end_with("/app/home")
      expect(response.cookies["hr_session"]).to be_present

      # the httpOnly cookie now authenticates a same-origin API request (no Bearer header)
      get "/api/v1/lk/status"
      expect(response.parsed_body["authenticated"]).to be(true)
      expect(response.parsed_body["email"]).to eq("web@himrate.test")
    end

    it "does not break the extension Bearer flow (unchanged, still returns JSON tokens)" do
      user = create(:user)
      allow(Auth::TwitchOauth).to receive(:new).and_return(instance_double(Auth::TwitchOauth, callback: user))
      Rails.cache.write("pkce:api1", { code_verifier: "v", redirect_uri: "https://cb" }, expires_in: 10.minutes)

      get "/api/v1/auth/twitch/callback", params: { code: "c", state: "api1" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["access_token"]).to be_present # JSON path, not a redirect
      expect(response.cookies["hr_session"]).to be_nil
    end
  end

  describe "GET /auth/web/google" do
    it "302-redirects the browser to the Google authorize URL and caches web-flagged state" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("GOOGLE_REDIRECT_URI").and_return("https://staging.himrate.com/api/v1/auth/google/callback")
      allow(Auth::GoogleOauth).to receive(:new).and_return(
        instance_double(Auth::GoogleOauth, authorize_url: { redirect_url: "https://accounts.google.com/o/oauth2/v2/auth?state=gst", state: "gst" })
      )
      get "/auth/web/google"
      expect(response).to have_http_status(:redirect)
      expect(response.location).to start_with("https://accounts.google.com/o/oauth2/v2/auth")
      expect(Rails.cache.read("google_state:gst")).to include(web: true, web_redirect: "/app/home")
    end
  end

  describe "web Google callback → cookie session" do
    it "sets an httpOnly session cookie that authenticates subsequent API requests" do
      user = create(:user, email: "gweb@himrate.test")
      allow(Auth::GoogleOauth).to receive(:new).and_return(instance_double(Auth::GoogleOauth, callback: user))
      Rails.cache.write("google_state:gw1", { redirect_uri: "https://cb", web: true, web_redirect: "/app/home" }, expires_in: 10.minutes)

      get "/api/v1/auth/google/callback", params: { code: "c", state: "gw1" }
      expect(response).to have_http_status(:redirect)
      expect(response.location).to end_with("/app/home")
      expect(response.cookies["hr_session"]).to be_present

      get "/api/v1/lk/status"
      expect(response.parsed_body["authenticated"]).to be(true)
      expect(response.parsed_body["email"]).to eq("gweb@himrate.test")
    end

    it "does not break the extension Google flow (unchanged, still returns JSON tokens)" do
      user = create(:user)
      allow(Auth::GoogleOauth).to receive(:new).and_return(instance_double(Auth::GoogleOauth, callback: user))
      Rails.cache.write("google_state:gapi", { redirect_uri: "https://cb" }, expires_in: 10.minutes)

      get "/api/v1/auth/google/callback", params: { code: "c", state: "gapi" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["access_token"]).to be_present # JSON path, not a redirect
      expect(response.cookies["hr_session"]).to be_nil
    end
  end

  describe "Bearer still authenticates (extension regression guard)" do
    it "authenticates via Authorization header as before" do
      user = create(:user, email: "ext@himrate.test")
      get "/api/v1/lk/status", headers: { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
      expect(response.parsed_body["authenticated"]).to be(true)
      expect(response.parsed_body["email"]).to eq("ext@himrate.test")
    end
  end

  describe "logout" do
    it "clears the session cookie via DELETE (no GET logout-CSRF vector)" do
      delete "/auth/web/logout"
      expect(response).to have_http_status(:no_content)
      # a subsequent API request is no longer authenticated
      get "/api/v1/lk/status"
      expect(response.parsed_body["authenticated"]).to be(false)
    end
  end
end
