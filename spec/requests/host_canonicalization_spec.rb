# frozen_string_literal: true

require "rails_helper"

# Host canonicalization (301) — host-mapping 2026-09. Marketing surfaces live on the apex
# (himrate.com, SEO-indexed); the product / LK lives on app.himrate.com under SHORT paths
# (app.himrate.com/home — the /app prefix is a legacy alias that 301s to the canon in one hop
# from anywhere). staging.himrate.com (same app/DB — a pure hostname alias) canonicalizes like
# any alias since the SEO-hygiene pass (Google was indexing the duplicate); /api/* untouched.
# Scoped to PagesController — API / auth / og / up are untouched.
RSpec.describe "Host canonicalization", type: :request do
  describe "marketing surfaces belong on the apex" do
    it "301s a marketing page served on the app host → apex" do
      host! "app.himrate.com"
      get "/brands"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://himrate.com/brands")
    end

    it "301s the BARE /streamers on the app host → apex (marketing page; LK owns only /streamers/:login)" do
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

  describe "product / LK canon = app host SHORT paths" do
    it "301s the login page served on the apex → app host" do
      host! "himrate.com"
      get "/login"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/login")
    end

    it "301s an apex /app/* page STRAIGHT to the app-host short path (one hop), preserving the query string" do
      host! "himrate.com"
      get "/app/discover?game=42"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/discover?game=42")
    end

    it "301s an app-host /app/* alias to the short path (strip prefix)" do
      host! "app.himrate.com"
      get "/app/social"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/social")
    end

    it "serves a short LK path on the app host without redirect" do
      host! "app.himrate.com"
      get "/social"

      expect(response).to have_http_status(:ok)
    end

    it "serves the LK streamer card on the app host short path" do
      host! "app.himrate.com"
      get "/streamers/ninja"

      expect(response).to have_http_status(:ok)
    end

    it "serves the app-host ROOT as the LK home (no redirect to apex)" do
      host! "app.himrate.com"
      get "/"

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

    it "product apex /app/* → app-host short resolves to a 200" do
      host! "himrate.com"
      get "/app/home"
      redirected = URI(response.location)

      host! redirected.host
      get redirected.path

      expect(response).to have_http_status(:ok)
    end

    it "app-host /app/* alias → short resolves to a 200" do
      host! "app.himrate.com"
      get "/app/home"
      redirected = URI(response.location)

      host! redirected.host
      get redirected.path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "host-aware robots.txt / sitemap (SEO)" do
    it "app host robots.txt ALLOWS crawling (deindexing via noindex — see the SEO-hygiene block) and never redirects" do
      host! "app.himrate.com"
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Allow: /")
      expect(response.body).not_to include("Disallow: /")
    end

    it "apex robots.txt keeps the marketing policy" do
      host! "himrate.com"
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Allow: /")
      expect(response.body).to include("Disallow: /app/")
      expect(response.body).to include("Sitemap: https://himrate.com/sitemap.xml")
    end

    it "app host sitemap.xml 301s to the apex sitemap (no duplicate content)" do
      host! "app.himrate.com"
      get "/sitemap.xml"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://himrate.com/sitemap.xml")
    end
  end

  describe "staging hostname canonicalizes (SEO-hygiene: it is the same app, a duplicate for Google)" do
    it "301s staging product pages to the app host short path" do
      host! "staging.himrate.com"
      get "/app/home"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/home")
    end

    it "301s the staging login to the app host" do
      host! "staging.himrate.com"
      get "/login"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/login")
    end

    it "301s staging marketing pages to the apex" do
      host! "staging.himrate.com"
      get "/streamers"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://himrate.com/streamers")
    end
  end

  describe "bare /app entry" do
    it "301s the naked /app to the canonical LK home from any host" do
      host! "himrate.com"
      get "/app"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to eq("https://app.himrate.com/home")
    end
  end

  describe "app-host deindexing signals (SEO-hygiene)" do
    it "app robots.txt ALLOWS crawling (Google must fetch pages to see their noindex)" do
      host! "app.himrate.com"
      get "/robots.txt"

      expect(response.body).to include("Allow: /")
      expect(response.body).not_to include("Disallow: /")
    end

    it "app-host pages carry the X-Robots-Tag noindex header" do
      host! "app.himrate.com"
      get "/home"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, follow")
    end

    it "apex pages carry NO X-Robots-Tag (marketing stays indexable)" do
      host! "himrate.com"
      get "/streamers"

      expect(response.headers["X-Robots-Tag"]).to be_nil
    end
  end

  describe "non-production hosts are left untouched" do
    it "does NOT redirect dev / localhost (default request host)" do
      get "/login" # default host is www.example.com — not a himrate.com host

      expect(response).to have_http_status(:ok)
    end
  end

  describe "routes/controller host constants stay in sync" do
    it "the routes host constraint matches PagesController::APP_HOST" do
      # routes.rb uses a literal (zeitwerk: no app constants in routes); this spec pins the pair.
      expect(PagesController::APP_HOST).to eq("app.himrate.com")
      expect(Rails.application.routes.routes.map { |r| r.constraints[:host] }.compact.uniq)
        .to eq([ "app.himrate.com" ])
    end
  end
end
