# frozen_string_literal: true

module PublicTop
  # EPIC-64 Phase 1: registry of Twitch categories that qualify for a public /top page
  # (enough distinct tracked channels over the 30-day window) and the slug → exact
  # category-name resolver. Slugs are lossy (transliterate + parameterize), so this
  # cached map — not reverse string surgery — is the source of truth. Backed by
  # trends_daily_aggregates.categories (jsonb game_name => streams_count), the same
  # store Brand::StreamerSearchQuery filters on, so the /top registry and the ranked
  # table can never disagree about what a category is.
  class Categories
    WINDOW_DAYS = Brand::StreamerSearchQuery::WINDOW_DAYS
    MIN_CHANNELS = 5
    MAX_CATEGORIES = 30
    CACHE_KEY = "public_top:categories:v1"
    CACHE_TTL = 6.hours

    def self.all = new.all

    def self.resolve(slug) = new.resolve(slug)

    # => [{ name:, slug:, channels: }, ...] ordered by tracked-channel count DESC.
    # Plain hashes (not Data/Struct) — the list crosses Rails.cache marshal boundaries.
    def all
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { compute }
    end

    def resolve(slug)
      all.find { |c| c[:slug] == slug }
    end

    private

    def compute
      window = WINDOW_DAYS.days.ago.to_date..Date.current
      rows = TrendsDailyAggregate
             .where(date: window)
             .joins("CROSS JOIN LATERAL jsonb_each(categories) AS cat(name, streams)")
             .group("cat.name")
             .having("COUNT(DISTINCT channel_id) >= ?", MIN_CHANNELS)
             .order(Arel.sql("COUNT(DISTINCT channel_id) DESC, cat.name ASC"))
             .limit(MAX_CATEGORIES * 2) # headroom: unsluggable / colliding names drop below
             .pluck(Arel.sql("cat.name"), Arel.sql("COUNT(DISTINCT channel_id)"))

      seen = {}
      rows.each do |name, channels|
        slug = slug_for(name)
        # Unsluggable (pure non-latin transliterates to "") or slug collision — the
        # larger category won (rows arrive count-DESC); the loser is skipped, not mangled.
        next if slug.blank? || seen.key?(slug)

        seen[slug] = { name: name, slug: slug, channels: channels }
        break if seen.size >= MAX_CATEGORIES
      end
      seen.values
    end

    def slug_for(name)
      ActiveSupport::Inflector.transliterate(name.to_s, "").parameterize
    end
  end
end
