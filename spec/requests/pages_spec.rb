# frozen_string_literal: true

require "rails_helper"

# TASK-060: the public marketing landing — a faithful Rails host of the Pencil
# export (5 pages). Public, unauthenticated GET surface; must stay reachable and
# carry the production assets (built Tailwind, self-hosted fonts, the export's JS).
RSpec.describe "Public landing", type: :request do
  PAGES = { "/" => "Главная", "/streamers" => "Стримерам", "/brands" => "Брендам",
            "/viewers" => "Зрителям", "/methodology" => "Методология" }.freeze

  describe "every page renders" do
    PAGES.each_key do |path|
      it "GET #{path} → 200 public HTML (no auth)" do
        get path

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/html")
        expect(response.body).to include('lang="ru"') # russian-first; client swap to EN
      end
    end
  end

  describe "GET /" do
    it "wires production assets: built Tailwind, self-hosted fonts, the export JS" do
      get "/"

      expect(response.body).to match(%r{/assets/tailwind[-\w]*\.css})
      expect(response.body).to match(%r{landing_fonts[-\w]*\.css})
      expect(response.body).to match(%r{landing/hr-i18n[-\w]*\.js})
      expect(response.body).to match(%r{landing/index[-\w]*\.js}) # self-contained index bundle
    end

    it "does not double the canvas/nav: index is self-contained (no hr-shared.js)" do
      get "/" # index.js carries its own canvas + nav

      expect(response.body).not_to match(%r{landing/hr-shared[-\w]*\.js})
    end

    it "loads the shared visual layer on the non-index pages" do
      get "/streamers"

      expect(response.body).to match(%r{landing/hr-shared[-\w]*\.js})
    end

    it "guards the FOUC: strips the static dot field + paints the dark bg up front" do
      get "/"

      expect(response.body).to include("background: #07070C")             # dark bg before JS
      expect(response.body).not_to include('data-pencil-name="Dot BG"')   # static dot field removed
    end

    it "keeps the page CSP-clean — no inline <script> (all JS externalized)" do
      get "/"

      expect(response.body).not_to match(%r{<script>}) # only <script src=...> tags
    end

    it "serves widest reach: a legacy browser UA is not blocked (no 406)" do
      get "/", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/50.0.2661.102 Safari/537.36" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "per-page content + JS bundle" do
    it "renders each page's distinctive content and loads its bundle" do
      { "/streamers" => "streamers", "/brands" => "brands",
        "/viewers" => "viewers", "/methodology" => "methodology" }.each do |path, page|
        get path

        expect(response.body).to match(%r{landing/#{page}[-\w]*\.js})
      end
    end
  end

  # TASK-060 SEO: Google was indexing the broken www host; canonicalise every page
  # onto the apex so it consolidates there. Keep LK shells + login out of the index.
  describe "SEO canonicalisation" do
    it "emits a self-referencing canonical on the apex host for each indexable page" do
      { "/" => "https://himrate.com/", "/streamers" => "https://himrate.com/streamers",
        "/methodology" => "https://himrate.com/methodology" }.each do |path, canonical|
        get path

        expect(response.body).to include(%(<link rel="canonical" href="#{canonical}">))
      end
    end

    it "sets og:url to the canonical apex URL (not the request host)" do
      get "/streamers"

      expect(response.body).to include('<meta property="og:url" content="https://himrate.com/streamers">')
    end

    it "keeps indexable marketing pages out of noindex" do
      get "/"

      expect(response.body).not_to match(/<meta name="robots" content="noindex/)
    end

    it "noindexes the login page (no public search value)" do
      get "/login"

      expect(response.body).to match(/<meta name="robots" content="noindex, follow">/)
    end
  end

  # TASK-060: analytics (Metrika + GA4) must load ONLY on the canonical production
  # host so staging / localhost never pollute the stats.
  describe "analytics gating" do
    it "loads the analytics bundle on the canonical host (himrate.com)" do
      host! "himrate.com"
      get "/"

      expect(response.body).to match(%r{landing/analytics[-\w]*\.js})
      expect(response.body).to include("mc.yandex.ru/watch/110889452") # noscript pixel
    end

    it "does NOT load analytics on a non-canonical host (staging/local)" do
      host! "staging.himrate.com"
      get "/"

      expect(response.body).not_to match(%r{landing/analytics[-\w]*\.js})
    end
  end

  # TASK-060: legal pages — required for Chrome Web Store submission + footer trust.
  describe "legal pages" do
    it "GET /privacy → 200 with the policy + self-canonical + footer nav" do
      get "/privacy"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Политика конфиденциальности")
      expect(response.body).to include('<link rel="canonical" href="https://himrate.com/privacy">')
      expect(response.body).to include('href="/terms"') # real crawlable footer link
    end

    it "GET /terms → 200 with the terms" do
      get "/terms"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Условия использования")
      expect(response.body).to include('<link rel="canonical" href="https://himrate.com/terms">')
    end
  end
end
