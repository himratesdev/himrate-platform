# frozen_string_literal: true

module PublicTop
  # EPIC-64 Phase 1: server-rendered rows for the public /top/:slug page. Thin public
  # wrapper over Brand::StreamerSearchQuery (params locked to: category, real-audience
  # sort, first page) that re-attaches the latest band color per channel (the brand
  # payload carries only the RU label) and exposes only public-safe fields — no
  # bot_correction_pct, no brand filter surface. Cached: the page is crawler-facing
  # and identical for every visitor.
  class CategoryTop
    PER_PAGE = 20
    CACHE_TTL = 1.hour
    WINDOW_DAYS = Brand::StreamerSearchQuery::WINDOW_DAYS

    def self.call(category_name) = new(category_name).call

    def initialize(category_name)
      @category = category_name
    end

    # => [{ rank:, login:, display_name:, real_avg_viewers:, shown_avg_viewers:,
    #       band_label:, band_tooltip:, band_color: }, ...]
    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute }
    end

    private

    def compute
      results = Brand::StreamerSearchQuery
                .new(category: @category, sort: "real_avg", per_page: PER_PAGE)
                .call[:results]
      bands = latest_bands(results.map { |r| r[:login] })

      results.each_with_index.map do |row, i|
        # The verdict badge renders only from a REAL v2 band (color persisted on the latest
        # in-window aggregate). Channels without one get nil/nil → the view hides the badge
        # entirely (hide-not-dim) — no mixed v1-fallback label under a guessed color.
        band = bands[row[:login]]
        color = band && band[:color]
        {
          rank: i + 1,
          login: row[:login],
          display_name: row[:display_name],
          real_avg_viewers: row[:real_avg_viewers],
          shown_avg_viewers: row[:shown_avg_viewers],
          band_label: color ? row[:classification_label] : nil,
          band_tooltip: color ? tooltip_for(band[:row]) : nil,
          band_color: color
        }
      end
    end

    # The scale hint behind the badge's label (config/locales/band.tooltip.*). Pinned to :ru like
    # the label it accompanies (Brand::StreamerSearchQuery#classification_label_for) — this payload
    # is cached under a locale-less key, so resolving the two texts in different locales is the one
    # thing that would actually break. A localized /top means a locale-scoped cache key first.
    def tooltip_for(band_row)
      return nil unless band_row

      I18n.t(TrustIndex::V2::BandClassifier.tooltip_key_for(band_row), locale: :ru, default: nil)
    end

    # login => { row:, color: } of the latest in-window band ("green"/"yellow"/"amber"/"red"/"grey").
    # Mirrors Brand::StreamerSearchQuery#load_latest_bands (which keeps band_row for its label) —
    # re-derived here instead of widening the brand contract for a public page.
    def latest_bands(logins)
      return {} if logins.empty?

      window = WINDOW_DAYS.days.ago.to_date..Date.current
      ids_by_login = Channel.where(login: logins).pluck(:login, :id).to_h
      latest = TrendsDailyAggregate
               .where(date: window, channel_id: ids_by_login.values)
               .select("DISTINCT ON (channel_id) channel_id, band_row_at_end, band_color_at_end")
               .order("channel_id, date DESC")
               .to_a
      bands_by_id = latest.to_h { |r| [ r.channel_id, { row: r[:band_row_at_end], color: r[:band_color_at_end] } ] }
      ids_by_login.transform_values { |id| bands_by_id[id] }
    end

    # v2: rows carry band_tooltip. Bumped so a warm v1 entry cannot serve the old shape for an hour.
    def cache_key
      "public_top:category:v2:#{Digest::SHA1.hexdigest(@category.to_s)}"
    end
  end
end
