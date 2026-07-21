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

    it "loads the shared visual layer on the marketing pages" do
      get "/streamers"

      expect(response.body).to match(%r{landing/hr-shared[-\w]*\.js})
    end

    it "does NOT load hr-shared.js on the LK/app surfaces (no nav-hijack, no animated bg)" do
      # hr-shared's nav-wiring hijacked the login Twitch button to /methodology, and its canvas
      # painted an animated background the product UI must not have.
      %w[/login /app/home /app/discover /app/search /c/recrent].each do |path|
        get path
        expect(response.body).not_to match(%r{landing/hr-shared[-\w]*\.js}), "expected no hr-shared.js on #{path}"
      end
    end

    # Layout split (app.himrate.com seam): the product surfaces (login + /app/*) render on the `app`
    # layout — noindex, product chrome, NO marketing SEO. The marketing pages + the public channel
    # card stay on the SEO-rich `landing` layout. Both layouts share tailwind/fonts via the head partial.
    it "renders login + /app/* on the app layout (noindex, no marketing SEO head)" do
      %w[/login /app/home /app/discover].each do |path|
        get path
        expect(response.body).to match(/<meta name="robots" content="noindex, follow">/), "#{path} must be noindex"
        expect(response.body).not_to include('application/ld+json'), "#{path} must not carry marketing JSON-LD"
        expect(response.body).not_to include('<link rel="canonical"'), "#{path} must not carry a marketing canonical"
        expect(response.body).to match(%r{/assets/tailwind[-\w]*\.css}), "#{path} still gets shared tailwind"
        expect(response.body).to match(%r{landing/brand_nav[-\w]*\.js}) if path.start_with?("/app/") # dashboard chrome
      end
    end

    it "keeps the public channel card on the landing layout (indexable SEO: canonical + OG + JSON-LD, but no hr-shared)" do
      create(:channel, login: "recrent")
      get "/c/recrent"

      expect(response.body).to include('<link rel="canonical"')                 # indexable
      expect(response.body).to include('application/ld+json')                    # marketing SEO head
      expect(response.body).to match(%r{<meta property="og:image" content=".*og/c/recrent\.png">}) # dynamic share image
      expect(response.body).not_to match(%r{landing/hr-shared[-\w]*\.js})        # its own chrome, no marketing nav
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

    it "falls back to the brand mark for og:image + mirrors it to twitter:image (no page override yet)" do
      get "/"

      expect(response.body).to match(%r{<meta property="og:image" content="https://himrate.com/assets/brand/logo-square-gradient[-\w]*\.svg">})
      expect(response.body).to match(%r{<meta name="twitter:image" content="https://himrate.com/assets/brand/logo-square-gradient[-\w]*\.svg">})
      expect(response.body).not_to include('property="og:image:width"') # dims only for custom PNGs
    end

    it "keeps indexable marketing pages out of noindex" do
      get "/"

      expect(response.body).not_to match(/<meta name="robots" content="noindex/)
    end

    it "emits Organization + WebSite JSON-LD structured data" do
      get "/"

      expect(response.body).to include('<script type="application/ld+json">')
      expect(response.body).to include('"@type": "Organization"')
      expect(response.body).to include('"@type": "WebSite"')
      expect(response.body).to include('"name": "HimRate"')
    end

    it "noindexes the login page (no public search value)" do
      get "/login"

      expect(response.body).to match(/<meta name="robots" content="noindex, follow">/)
    end

    it "points a known channel-card share link at its dynamic OG image + 1200x630 hints" do
      create(:channel, login: "ninja")
      get "/c/ninja"

      expect(response.body).to include('<meta property="og:image" content="https://himrate.com/og/c/ninja.png">')
      expect(response.body).to include('<meta property="og:image:width" content="1200">')
      expect(response.body).to include('<meta name="twitter:image" content="https://himrate.com/og/c/ninja.png">')
    end

    it "404s an unknown channel card (no soft-404 / indexable empty page)" do
      get "/c/definitely_not_a_real_channel"

      expect(response).to have_http_status(:not_found)
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
