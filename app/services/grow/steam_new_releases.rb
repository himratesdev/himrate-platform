# frozen_string_literal: true

module Grow
  # Screen 13 «Рост» — the «новинка в Steam» candidate pool. Reads Steam's public storefront JSON
  # (store.steampowered.com/api/featuredcategories — no key; DSV growth-sources-probe run
  # 29781151115: new_releases = 30 real items). Called from the refresh worker only (HTTP off the
  # request path). Returns [{ steam_id:, name: }]; [] on any failure (worker keeps the stale cache).
  class SteamNewReleases
    URL = "https://store.steampowered.com/api/featuredcategories?cc=us&l=en"
    TIMEOUT = 10

    def call
      response = HTTP.timeout(TIMEOUT).get(URL)
      return [] unless response.status.success?

      items = JSON.parse(response.body.to_s).dig("new_releases", "items") || []
      items.filter_map do |item|
        name = item["name"].to_s.strip
        next if name.empty?

        { steam_id: item["id"], name: name }
      end
    rescue HTTP::Error, JSON::ParserError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Grow::SteamNewReleases failed: #{e.class}: #{e.message[0..120]}")
      []
    end
  end
end
