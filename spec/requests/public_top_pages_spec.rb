# frozen_string_literal: true

require "rails_helper"

# EPIC-64 Phase 1: the public /top pages — server-rendered category tops (the content
# IS the SEO payload, so it must be in the primary HTML, not client-fetched).
RSpec.describe "Public category tops", type: :request do
  before { Rails.cache.clear }

  def seed_dota(channels: PublicTop::Categories::MIN_CHANNELS)
    channels.times do |i|
      ch = create(:channel, login: "dota_ch#{i}")
      create(:stream, channel: ch, game_name: "Dota 2", started_at: 1.hour.ago)
      create(:trends_daily_aggregate, channel: ch, date: 2.days.ago.to_date,
                                      ccv_avg: 1000 * (i + 1), erv_avg_percent: 90.0,
                                      categories: { "Dota 2" => 1 },
                                      band_row_at_end: 1, band_color_at_end: "green")
    end
  end

  describe "GET /top" do
    it "renders the index with crawlable category links, exactly one h1 and a canonical" do
      seed_dota

      get "/top"

      expect(response).to have_http_status(:ok)
      expect(response.body.scan(/<h1[\s>]/).size).to eq(1)
      expect(response.body).to include('<link rel="canonical" href="https://himrate.com/top">')
      expect(Nokogiri::HTML(response.body).css('a[href="/top/dota-2"]')).to be_present
      expect(response.body).to include("каналов под наблюдением")
    end

    it "renders an honest empty state when nothing qualifies" do
      get "/top"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Категории появятся")
    end
  end

  describe "GET /top/:slug" do
    it "server-renders the ranked table: rows, links to /c/, verdict badges, ItemList JSON-LD" do
      seed_dota(channels: 6)

      get "/top/dota-2"

      expect(response).to have_http_status(:ok)
      expect(response.body.scan(/<h1[\s>]/).size).to eq(1)
      expect(response.body).to include("Топ стримеров — Dota 2")
      # rows are in the PRIMARY html (crawler-facing), ranked, linked to the channel card
      doc = Nokogiri::HTML(response.body)
      row_links = doc.css('a[href^="/c/dota_ch"]')
      expect(row_links.size).to eq(6)
      expect(response.body).to include("АУДИТОРИЯ (30Д)")
      # the top channel (highest real audience) is ranked #1
      expect(response.body.index("dota_ch5")).to be < response.body.index("dota_ch0")
      # verdict badge from the v2 band (legal-safe label, no «% ботов» anywhere)
      expect(response.body).not_to include("ботов")
      # ItemList JSON-LD for rich results
      expect(response.body).to include('"@type":"ItemList"')
      # crawlable marketing nav (same contract as the marketing pages)
      nav = doc.at_css("nav[aria-label='Основная навигация']")
      expect(nav).to be_present
      expect(nav.css("a[href]")).to be_present
    end

    it "404s an unknown slug with the static 404 page (no soft-404 shell)" do
      get "/top/unknown-slug"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /c/:login (EPIC-64 SEO hardening)" do
    it "carries exactly one h1 with the server-rendered login and BreadcrumbList JSON-LD" do
      create(:channel, login: "recrent")

      get "/c/recrent"

      expect(response).to have_http_status(:ok)
      expect(response.body.scan(/<h1[\s>]/).size).to eq(1)
      expect(response.body).to match(%r{<h1[^>]*>\s*recrent\s*</h1>}m)
      expect(response.body).to include('"@type":"BreadcrumbList"')
    end

    it "links to the category top when the channel's latest category qualifies" do
      seed_dota
      ch = create(:channel, login: "linked_ch")
      create(:stream, channel: ch, game_name: "Dota 2", started_at: 30.minutes.ago)

      get "/c/linked_ch"

      expect(Nokogiri::HTML(response.body).css('a[href="/top/dota-2"]')).to be_present
    end

    it "hides the top link when the category does not qualify" do
      ch = create(:channel, login: "solo_ch")
      create(:stream, channel: ch, game_name: "Rare Game", started_at: 30.minutes.ago)

      get "/c/solo_ch"

      expect(Nokogiri::HTML(response.body).css('a[href^="/top/"]')).to be_empty
    end
  end
end
