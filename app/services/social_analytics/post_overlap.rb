# frozen_string_literal: true

module SocialAnalytics
  # Cross-channel POST overlap: which Telegram channels publish the same content, and when a
  # channel's own posts travelled beyond it.
  #
  # Two products come out of one query. For a brand: «этот пост уже вышел в пяти каналах» — the
  # reach it is being sold is shared, not additive. For interpretation: a view spike stops looking
  # like inflation the moment you see the post was reposted (or was a giveaway).
  #
  # Basis is the public preview we store in social_posts — same normalized-text hash across
  # channels within a short window is a repost; identical text months apart is a template, not a
  # coordinated push, hence the window.
  class PostOverlap
    WINDOW_HOURS = 48
    MIN_CHANNELS = 2
    LOOKBACK_DAYS = 90

    def initialize(client: Clickhouse::Client.new)
      @client = client
    end

    # → [{ text_hash:, channels: [...], posts:, first_at:, sample_text:, total_views: }]
    # Repost clusters over the whole corpus, biggest first.
    def clusters(limit: 50)
      rows = @client.select(<<~SQL)
        SELECT text_hash,
               groupUniqArray(handle) AS handles,
               count() AS posts,
               min(published_at) AS first_at,
               max(published_at) AS last_at,
               sum(views) AS total_views,
               any(text) AS sample_text
        FROM #{table}
        WHERE published_at > now() - INTERVAL #{LOOKBACK_DAYS} DAY AND text_hash != 0
        GROUP BY text_hash
        HAVING uniqExact(handle) >= #{MIN_CHANNELS}
           AND dateDiff('hour', min(published_at), max(published_at)) <= #{WINDOW_HOURS}
        ORDER BY posts DESC, total_views DESC
        LIMIT #{limit.to_i}
      SQL
      rows.map { |r| shape(r) }
    end

    # Context for ONE channel — what the observations layer needs to explain its numbers.
    # → { reposted:, repost_partners:, giveaway:, posts_seen: }
    def context_for(handle)
      escaped = handle.to_s.downcase.gsub("'", "''")
      # ClickHouse has no correlated subqueries ("Resolve identifier from parent scope only supported
      # for constants and CTE") — pre-aggregate how many channels carry each text, then join.
      row = @client.select(<<~SQL).first
        WITH spread AS (
          SELECT text_hash, uniqExact(handle) AS channels
          FROM #{table}
          WHERE published_at > now() - INTERVAL #{LOOKBACK_DAYS} DAY AND text_hash != 0
          GROUP BY text_hash
        )
        SELECT countIf(s.channels > 1) AS reposted_posts,
               countIf(p.has_giveaway = 1) AS giveaway_posts,
               count() AS posts_seen
        FROM #{table} AS p
        LEFT JOIN spread AS s ON s.text_hash = p.text_hash
        WHERE lower(p.handle) = '#{escaped}'
          AND p.published_at > now() - INTERVAL #{LOOKBACK_DAYS} DAY
      SQL
      return {} if row.nil?

      { reposted: row["reposted_posts"].to_i.positive?,
        giveaway: row["giveaway_posts"].to_i.positive?,
        posts_seen: row["posts_seen"].to_i }
    rescue StandardError => e
      Rails.logger.warn("SocialAnalytics::PostOverlap[#{handle}]: #{e.class} — no post context")
      {}
    end

    private

    def table
      "social_posts"
    end

    def shape(row)
      { text_hash: row["text_hash"],
        channels: Array(row["handles"]),
        posts: row["posts"].to_i,
        first_at: row["first_at"],
        last_at: row["last_at"],
        total_views: row["total_views"].to_i,
        sample_text: row["sample_text"].to_s.slice(0, 200) }
    end
  end
end
