# frozen_string_literal: true

module Search
  # Free-text channel lookup: the one thing the product had no way to do — type a nickname and find
  # the channel. Matches on BOTH the Twitch identity (login / display name) and the linked social
  # handles (Telegram, YouTube, TikTok, VK, Instagram, …), so a brand that only knows "@DearHellGirl
  # from Telegram" still lands on the right streamer.
  #
  # Ranking is deliberate, not relevance-magic: exact login first, then prefix, then the rest,
  # tie-broken by follower count — a brand searching "kate" wants the big Kate first.
  class ChannelLookup
    MIN_QUERY = 2
    LIMIT = 20

    Result = Struct.new(:channel, :matched_on, :matched_value, keyword_init: true)

    def initialize(query, limit: LIMIT)
      @raw = query.to_s.strip
      # Accept what people actually paste: "@handle", "t.me/handle", "twitch.tv/login", full URLs.
      @q = @raw.downcase.sub(%r{\Ahttps?://}, "").sub(/\A@/, "")
               .sub(%r{\A(www\.)?(t\.me/(s/)?|twitch\.tv/|youtube\.com/@?|tiktok\.com/@|vk\.com/|instagram\.com/)}, "")
               .split(%r{[/?#]}).first.to_s
      @limit = limit.to_i.clamp(1, 50)
    end

    def call
      return [] if @q.length < MIN_QUERY

      results = by_identity + by_social
      dedup(results).first(@limit)
    end

    private

    def like
      @like ||= "%#{ActiveRecord::Base.sanitize_sql_like(@q)}%"
    end

    def by_identity
      Channel.active
             .where("LOWER(login) LIKE :q OR LOWER(display_name) LIKE :q", q: like)
             .order(Arel.sql(<<~SQL))
               CASE WHEN LOWER(login) = #{Channel.connection.quote(@q)} THEN 0
                    WHEN LOWER(login) LIKE #{Channel.connection.quote("#{@q}%")} THEN 1
                    ELSE 2 END,
               COALESCE(followers_total, 0) DESC
             SQL
             .limit(@limit)
             .map { |c| Result.new(channel: c, matched_on: "twitch", matched_value: c.login) }
    end

    # Social handles live in channel_social_links (platform + url; handle when we parsed one).
    # Matching the URL too means a pasted "t.me/DearHellGirl" finds the channel even when the
    # handle column is blank.
    def by_social
      links = ChannelSocialLink.where("LOWER(handle) LIKE :q OR LOWER(url) LIKE :q", q: like)
                               .limit(@limit * 2)
      return [] if links.empty?

      channels = Channel.active.where(id: links.map(&:channel_id)).index_by(&:id)
      links.filter_map do |link|
        channel = channels[link.channel_id]
        next unless channel

        Result.new(channel: channel, matched_on: link.platform,
                   matched_value: link.handle.presence || link.url)
      end
    end

    # One row per channel; an identity match wins over a social one (it is the stronger signal).
    def dedup(results)
      results.uniq { |r| r.channel.id }
    end
  end
end
