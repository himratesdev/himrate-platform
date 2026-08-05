# frozen_string_literal: true

require "rails_helper"

# TASK-060 SEO: the sitemap is the authoritative discovery channel — the Pencil nav
# is JS-driven, not crawlable <a href>. robots.txt points Google at it.
# EPIC-64: + dynamic /top category pages and the curated /c/:login set (gated:
# ≥10 streams in-window AND a present band verdict on the latest aggregate).
RSpec.describe "Sitemap + robots", type: :request do
  before { Rails.cache.clear }

  describe "GET /sitemap.xml" do
    it "returns 200 well-formed sitemaps.org XML" do
      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/xml")
      doc = Nokogiri::XML(response.body)
      expect(doc.errors).to be_empty
      expect(doc.root.name).to eq("urlset")
    end

    it "lists every indexable marketing + legal page on the canonical apex host" do
      get "/sitemap.xml"

      %w[/ /streamers /brands /viewers /methodology /privacy /terms].each do |path|
        expect(response.body).to include("<loc>https://himrate.com#{path}</loc>")
      end
    end

    it "excludes LK app shells, login and API routes" do
      get "/sitemap.xml"

      expect(response.body).not_to include("/app/")
      expect(response.body).not_to include("/login")
      expect(response.body).not_to include("/api/")
    end

    it "omits /top and /c/ entirely while nothing qualifies (no empty-index junk)" do
      get "/sitemap.xml"

      expect(response.body).not_to include("/top")
      expect(response.body).not_to include("/c/")
    end

    context "with qualifying top categories and curated channels" do
      before do
        # Category above the /top gate (MIN_CHANNELS distinct channels).
        PublicTop::Categories::MIN_CHANNELS.times do
          create(:trends_daily_aggregate, channel: create(:channel), date: 2.days.ago.to_date,
                                          categories: { "Dota 2" => 1 })
        end
        # Curated /c/ channel: ≥10 in-window streams AND a band on the latest aggregate.
        curated = create(:channel, login: "curated_ch")
        create(:trends_daily_aggregate, channel: curated, date: 2.days.ago.to_date,
                                        streams_count: 10, categories: { "Dota 2" => 1 },
                                        band_row_at_end: 1, band_color_at_end: "green")
        # Active but band-less channel — stays out of the curated set.
        bandless = create(:channel, login: "bandless_ch")
        create(:trends_daily_aggregate, channel: bandless, date: 2.days.ago.to_date,
                                        streams_count: 10, categories: { "Dota 2" => 1 },
                                        band_row_at_end: nil, band_color_at_end: nil)
      end

      it "lists /top, each qualifying category page and only banded active channels" do
        get "/sitemap.xml"

        expect(response.body).to include("<loc>https://himrate.com/top</loc>")
        expect(response.body).to include("<loc>https://himrate.com/top/dota-2</loc>")
        expect(response.body).to include("<loc>https://himrate.com/c/curated_ch</loc>")
        expect(response.body).not_to include("/c/bandless_ch")
      end
    end
  end

  describe "GET /robots.txt" do
    it "advertises the sitemap and disallows non-public paths" do
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sitemap: https://himrate.com/sitemap.xml")
      expect(response.body).to include("Disallow: /app/")
      expect(response.body).to include("Disallow: /api/")
    end
  end
end
