# frozen_string_literal: true

require "rails_helper"

# TASK-060 Phase 0: the public marketing landing root. Landing is a public,
# unauthenticated surface and must stay reachable as later phases add the
# literal-ported pages — guard root from silently breaking (build-complete-now).
RSpec.describe "Public landing", type: :request do
  describe "GET /" do
    it "renders the landing root as public HTML with 200 (no auth)" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
    end

    it "is Russian-first: <html lang=ru> by default" do
      get "/"

      expect(response.body).to include('lang="ru"')
    end

    it "switches locale via ?locale=en" do
      get "/", params: { locale: "en" }

      expect(response.body).to include('lang="en"')
    end

    it "falls back to ru for an unsupported locale" do
      get "/", params: { locale: "zz" }

      expect(response.body).to include('lang="ru"')
    end

    it "serves widest reach: a legacy browser UA is not blocked (no 406)" do
      get "/", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/50.0.2661.102 Safari/537.36" }

      expect(response).to have_http_status(:ok)
    end

    it "wires the self-hosted fonts and the landing JS layer" do
      get "/"

      expect(response.body).to match(%r{landing_fonts[-\w]*\.css})
      expect(response.body).to match(%r{landing/hr-shared[-\w]*\.js})
    end
  end

  # TASK-060 Phase 1: Slot A (Header + Hero + Explainer) literal port.
  describe "Slot A (header + hero)" do
    it "bakes the final header — menu + the post-fixHeader action buttons" do
      get "/"

      %w[СТРИМЕРАМ БРЕНДАМ ЗРИТЕЛЯМ].each { |item| expect(response.body).to include(item) }
      expect(response.body).to include("МЕТОДОЛОГИЯ И ЦЕНЫ")          # ЦЕНЫ merged in
      expect(response.body).to include("Открыть сервис")
      expect(response.body).to include("Открыть расширение")
      expect(response.body).to include("Подключить канал")
    end

    it "recolors the wordmark mark to the export's final accent (#67E8F9)" do
      get "/"

      expect(response.body).to include('fill="#67E8F9"')
      expect(response.body).to include('viewBox="0 -9 176.3 53.9"') # SVG camelCase preserved
    end

    it "wires nav + CTAs to centralized links with stable analytics hooks" do
      get "/"

      expect(response.body).to include('data-hr-href="/"')          # wordmark → home
      expect(response.body).to include('data-evt="nav:streamers"')
      expect(response.body).to include('data-evt="cta:connect"')
    end

    it "offers a server-side RU/EN locale switch in the header" do
      get "/"

      expect(response.body).to include('href="/?locale=en"')
      expect(response.body).to include('href="/?locale=ru"')
    end

    it "renders RU verbatim by default (no English leakage)" do
      get "/"

      expect(response.body).to include("СТРИМЕРАМ")
      expect(response.body).not_to include("FOR STREAMERS")
    end

    it "server-renders the English variant via the dictionary (SEO, not a client swap)" do
      get "/", params: { locale: "en" }

      expect(response.body).to include("FOR STREAMERS")          # СТРИМЕРАМ text node
      expect(response.body).to include("METHODOLOGY &amp; PRICING")
      expect(response.body).to include("Connect a channel")
    end
  end
end
