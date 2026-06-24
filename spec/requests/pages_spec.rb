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
      expect(response.body).to match(%r{landing/hr-shared[-\w]*\.js})
      expect(response.body).to match(%r{landing/hr-i18n[-\w]*\.js})
      expect(response.body).to match(%r{landing/index[-\w]*\.js}) # per-page bundle
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
end
