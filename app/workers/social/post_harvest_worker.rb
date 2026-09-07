# frozen_string_literal: true

module Social
  # Store the public posts of streamers' Telegram channels so a view spike can be EXPLAINED.
  #
  # A channel-level average says a post did 3× the usual views; only the posts themselves say why —
  # a giveaway, or the same text reposted across a dozen channels. That is the difference between
  # «reach a brand can buy» and «one contest». Persisting them also gives us cross-channel post
  # overlap: identical text in several channels at once = a repost network, visible with one GROUP BY.
  #
  # Public preview only (t.me/s/<handle>) — nothing private. Bounded per run; the profile fetch is
  # external HTTP, so this lives on :long_running, never on a request path.
  class PostHarvestWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 1

    MAX_CHANNELS_PER_RUN = 60
    TABLE = "social_posts"
    GIVEAWAY_WORDS = SocialAnalytics::Telegram::Observations::GIVEAWAY_WORDS

    def perform
      handles = telegram_handles
      return if handles.empty?

      rows = handles.flat_map { |handle| harvest(handle) }.compact
      return if rows.empty?

      Clickhouse::Client.new.insert(TABLE, rows)
      Rails.logger.info("Social::PostHarvestWorker: #{rows.size} posts from #{handles.size} channels")
    end

    private

    # Channels we know a Telegram handle for — from the Twitch panel or harvested from chat.
    def telegram_handles
      ChannelSocialLink.where(platform: "telegram").where.not(handle: [ nil, "" ])
                       .order(Arel.sql("random()"))
                       .limit(MAX_CHANNELS_PER_RUN)
                       .pluck(:handle).uniq
    end

    def harvest(handle)
      profile = SocialAnalytics::Telegram::PublicProfile.call(handle)
      return [] if profile.nil?

      (profile[:posts] || []).filter_map { |post| row_for(handle, post) }
    rescue StandardError => e
      Rails.logger.warn("Social::PostHarvestWorker[#{handle}]: #{e.class}: #{e.message&.slice(0, 120)}")
      []
    end

    def row_for(handle, post)
      published = parse_time(post[:at])
      return nil if published.nil?

      text = post[:text].to_s
      {
        platform: "telegram",
        handle: handle,
        # Preview ids look like "channel/1234"; keep the numeric part so the key is stable even if
        # the channel is renamed.
        post_id: post[:post_id].to_s.split("/").last.presence || published.to_i.to_s,
        published_at: published.utc.strftime("%Y-%m-%d %H:%M:%S"),
        views: post[:views].to_i,
        text: text.slice(0, 2000),
        text_hash: text_hash(text),
        links: Array(post[:links]).first(5),
        has_giveaway: text.match?(GIVEAWAY_WORDS) ? 1 : 0
      }
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    # Normalized so trivial edits (spacing, case, emoji-only diffs) do not hide a repost. Empty text
    # hashes to 0 — a media-only post must never look "identical" to every other media-only post.
    def text_hash(text)
      normalized = text.downcase.gsub(/\s+/, " ").gsub(/[^\p{Alnum} ]/, "").strip
      return 0 if normalized.length < 20

      Digest::MD5.hexdigest(normalized)[0, 15].to_i(16)
    end
  end
end
