# frozen_string_literal: true

require "rails_helper"

# Subdomain split step 2 — host canonicalization (301). Marketing surfaces live on the apex
# (himrate.com, SEO-indexed); the product / LK lives on app.himrate.com (noindex). Each surface
# has exactly ONE canonical URL. Scoped to PagesController — API / auth / og / up are untouched.
RSpec.describe "Host canonicalization", type: :request do
  describe "marketing surfaces belong on the apex" do
    it "301s a marketing page served on the app host → apex" do
      host! "app.himrate.com"
      get "/streamers"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://himrate.com/streamers")
    end

    it "301s the public channel card served on the app host → apex (keeps SEO on the apex)" do
      host! "app.himrate.com"
      get "/c/ninja"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://himrate.com/c/ninja")
    end

    it "serves a marketing page on the apex without redirect" do
      host! "himrate.com"
      get "/streamers"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "product / LK surfaces belong on the app host" do
    it "301s the login page served on the apex → app host" do
      host! "himrate.com"
      get "/login"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/login")
    end

    it "301s an /app/* page served on the apex → app host, preserving the query string" do
      host! "himrate.com"
      get "/app/discover?game=42"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/app/discover?game=42")
    end

    it "serves an /app/* page on the app host without redirect" do
      host! "app.himrate.com"
      get "/app/social"

      expect(response).to have_http_status(:ok)
    end

    it "serves the login page on the app host without redirect" do
      host! "app.himrate.com"
      get "/login"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "no redirect loop — following the 301 lands on a 200 in one hop" do
    it "marketing app→apex resolves to a 200" do
      host! "app.himrate.com"
      get "/streamers"
      redirected = URI(response.location)

      host! redirected.host
      get redirected.path

      expect(response).to have_http_status(:ok)
    end

    it "product apex→app resolves to a 200" do
      host! "himrate.com"
      get "/login"
      redirected = URI(response.location)

      host! redirected.host
      get redirected.path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "non-production hosts are left untouched" do
    it "does NOT redirect the staging test host (serves product on staging)" do
      host! "staging.himrate.com"
      get "/login"

      expect(response).to have_http_status(:ok)
    end

    it "does NOT redirect the staging test host (serves marketing on staging)" do
      host! "staging.himrate.com"
      get "/streamers"

      expect(response).to have_http_status(:ok)
    end

    it "does NOT redirect dev / localhost (default request host)" do
      get "/login" # default host is www.example.com — not a himrate.com host

      expect(response).to have_http_status(:ok)
    end
  end
end
