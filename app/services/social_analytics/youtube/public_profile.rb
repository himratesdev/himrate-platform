# frozen_string_literal: true

module SocialAnalytics
  module Youtube
    # YouTube public-channel adapter (SA-1). DESCRIPTIVE metrics for a streamer's linked YouTube channel
    # (discovered from Twitch socialMedias) — subscribers, total views, video count, and recent-video
    # engagement (avg views/likes/comments + ER). Public YouTube Data API v3 (YOUTUBE_API_KEY), ~3 quota
    # units per profile (channels.list 1 + playlistItems 1 + videos 1) → ~3k profiles/day on the default
    # 10k quota. No fraud/накрутка verdict (PO 2026-07-21: descriptive only, bot-detection is Twitch-only).
    #
    # Channel resolution handles every URL form Twitch hands us (/channel/UC…, /@handle, /user/name, and
    # the legacy /c/custom — which the API can't resolve directly): fetch the channel page HTML once and
    # pull the canonical channelId, then channels.list?id= (reliable, 1 unit). Sidekiq-only (external HTTP).
    class PublicProfile
      API = "https://www.googleapis.com/youtube/v3"
      TIMEOUT = 10
      RECENT_VIDEOS = 15
      USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
                   "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

      def self.call(url)
        new(url).call
      end

      def initialize(url)
        @url = url.to_s
      end

      def call
        return nil if api_key.blank? || @url.blank?

        channel_id = resolve_channel_id
        return nil unless channel_id

        channel = fetch_channel(channel_id)
        return nil unless channel

        videos = channel[:uploads_playlist] ? fetch_recent_video_stats(channel[:uploads_playlist]) : []
        self.class.build(channel, videos)
      rescue HTTP::Error, OpenSSL::SSL::SSLError, SocketError, SystemCallError, Timeout::Error, JSON::ParserError => e
        Rails.logger.warn("SocialAnalytics::Youtube::PublicProfile #{@url}: #{e.class}: #{e.message[0..120]}")
        nil
      end

      # ── resolution ──────────────────────────────────────────────────────────
      # A /channel/UC… URL carries the id directly; anything else (/@handle, /user, /c/custom) is resolved
      # by reading the canonical channelId out of the page HTML (keyless, one fetch, form-agnostic).
      def resolve_channel_id
        direct = @url[%r{youtube\.com/channel/(UC[A-Za-z0-9_-]{22})}, 1]
        return direct if direct

        html = get_raw(@url)
        html && html[/"channelId":"(UC[A-Za-z0-9_-]{22})"/, 1]
      end

      def fetch_channel(channel_id)
        data = api_get("/channels", part: "snippet,statistics,contentDetails", id: channel_id)
        item = data && (data["items"] || []).first
        return nil unless item

        stats = item["statistics"] || {}
        {
          channel_id: channel_id,
          title: item.dig("snippet", "title"),
          subscribers: stats["hiddenSubscriberCount"] ? nil : stats["subscriberCount"]&.to_i,
          total_views: stats["viewCount"]&.to_i,
          video_count: stats["videoCount"]&.to_i,
          uploads_playlist: item.dig("contentDetails", "relatedPlaylists", "uploads")
        }
      end

      def fetch_recent_video_stats(uploads_playlist)
        pl = api_get("/playlistItems", part: "contentDetails", playlistId: uploads_playlist, maxResults: RECENT_VIDEOS)
        ids = (pl && pl["items"] || []).filter_map { |i| i.dig("contentDetails", "videoId") }
        return [] if ids.empty?

        vids = api_get("/videos", part: "statistics", id: ids.join(","))
        (vids && vids["items"] || []).map do |v|
          s = v["statistics"] || {}
          { views: s["viewCount"]&.to_i, likes: s["likeCount"]&.to_i, comments: s["commentCount"]&.to_i }
        end
      end

      # ── pure metric assembly (testable) ─────────────────────────────────────
      def self.build(channel, videos)
        {
          channel_id: channel[:channel_id],
          title: channel[:title],
          subscribers: channel[:subscribers],
          total_views: channel[:total_views],
          video_count: channel[:video_count],
          metrics: compute_metrics(channel, videos),
          captured_at: nil # stamped by the caller
        }
      end

      def self.compute_metrics(channel, videos)
        views = videos.filter_map { |v| v[:views] }
        avg_views = views.any? ? (views.sum.to_f / views.size).round : nil
        engagements = videos.filter_map { |v| ((v[:likes] || 0) + (v[:comments] || 0)) if v[:views] }
        avg_eng = engagements.any? ? (engagements.sum.to_f / engagements.size).round : nil
        {
          recent_videos: videos.size,
          avg_views: avg_views,
          avg_engagement: avg_eng,
          # ER (вовлечённость) — avg (likes+comments) ÷ avg views (%). Same engagement metric shown by
          # LabelUp/Social Blade. Descriptive, no verdict.
          er_percent: (avg_eng && avg_views&.positive? ? (avg_eng.to_f / avg_views * 100).round(2) : nil),
          # views-per-subscriber (лайфтайм) — a rough reach descriptor (total views ÷ subscribers).
          views_per_sub: (channel[:total_views] && channel[:subscribers]&.positive? ? (channel[:total_views].to_f / channel[:subscribers]).round(1) : nil)
        }
      end

      private

      def api_key
        ENV["YOUTUBE_API_KEY"].to_s
      end

      def api_get(path, **params)
        r = HTTP.timeout(TIMEOUT).get("#{API}#{path}", params: params.merge(key: api_key))
        r.status.success? ? JSON.parse(r.body.to_s) : nil
      end

      def get_raw(url)
        r = HTTP.headers("User-Agent" => USER_AGENT).timeout(TIMEOUT).get(url)
        r.status.success? ? r.body.to_s : nil
      end
    end
  end
end
