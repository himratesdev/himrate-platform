# frozen_string_literal: true

require "rails_helper"

# TASK-060 SEO: the sitemap is the authoritative discovery channel — the Pencil nav
# is JS-driven, not crawlable <a href>. robots.txt points Google at it.
RSpec.describe "Sitemap + robots", type: :request do
  describe "GET /sitemap.xml" do
    before { get "/sitemap.xml" }

    it "returns 200 XML" do
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/xml")
    end

    it "lists every indexable marketing page on the canonical apex host" do
      %w[/ /streamers /brands /viewers /methodology].each do |path|
        expect(response.body).to include("<loc>https://himrate.com#{path}</loc>")
      end
    end

    it "excludes LK app shells, login and API routes" do
      expect(response.body).not_to include("/app/")
      expect(response.body).not_to include("/login")
      expect(response.body).not_to include("/api/")
    end

    it "is well-formed sitemaps.org XML" do
      doc = Nokogiri::XML(response.body)
      expect(doc.errors).to be_empty
      expect(doc.root.name).to eq("urlset")
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
