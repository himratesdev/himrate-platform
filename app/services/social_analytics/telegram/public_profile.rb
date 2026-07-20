# frozen_string_literal: true

module SocialAnalytics
  module Telegram
    # Telegram PUBLIC-channel adapter (SA-1/03, keyless — the `t.me/s/<handle>` web preview needs no
    # bot token; verified live 2026-07-21: recrent = 236K subs, 40 posts, per-post views ~70K). Exposes
    # what the preview reliably carries: subscriber count + the last ~20 posts {views, timestamp, media}.
    # Deeper signals (reactions, comments, dormant-member %, join-burst) need the Bot API / MTProto and
    # are honest-deferred until the streamer links `@himrate_bot` (Phase-1.5).
    #
    # `fetch` does external HTTP → Sidekiq-only (mirrors the HelixClient/GqlClient convention). `parse`
    # is a pure function on the HTML so it's unit-testable against a captured fixture.
    class PublicProfile
      SOURCE_URL = "https://t.me/s/%s"
      TIMEOUT = 10
      USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
                   "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

      def self.call(handle)
        new(handle).call
      end

      def initialize(handle)
        @handle = handle.to_s.strip.delete_prefix("@")
      end

      def call
        return nil if @handle.blank?

        html = fetch
        html && self.class.parse(html, handle: @handle)
      rescue HTTP::Error, OpenSSL::SSL::SSLError => e
        Rails.logger.warn("SocialAnalytics::Telegram::PublicProfile #{@handle}: #{e.class}: #{e.message[0..120]}")
        nil
      end

      def fetch
        response = HTTP.headers("User-Agent" => USER_AGENT).timeout(TIMEOUT).get(format(SOURCE_URL, @handle))
        response.status.success? ? response.body.to_s : nil
      end

      # Pure parser — no I/O. Returns nil when the page carries no channel signal (private/not found).
      def self.parse(html, handle: nil)
        subscribers = parse_subscribers(html)
        posts = parse_posts(html)
        return nil if subscribers.nil? && posts.empty?

        {
          handle: handle,
          title: parse_title(html),
          subscribers: subscribers,
          posts: posts,
          metrics: compute_metrics(subscribers, posts),
          captured_at: nil # stamped by the caller (Time.current unavailable in pure context)
        }
      end

      def self.parse_subscribers(html)
        m = html.match(/([\d  .,]+[KM]?)\s*(?:subscribers|members|подписчик)/i)
        m && to_i(m[1])
      end

      def self.parse_title(html)
        m = html.match(/tgme_channel_info_header_title[^>]*>\s*<[^>]*>([^<]+)/) ||
            html.match(/tgme_channel_info_header_title[^>]*>([^<]+)/)
        m && m[1].strip.presence
      end

      # Each message bubble carries a views span + an ISO datetime; media presence is a photo/video wrap.
      def self.parse_posts(html)
        views = html.scan(/tgme_widget_message_views">([^<]+)</).flatten
        dates = html.scan(/datetime="([^"]+)"/).flatten
        n = [ views.size, dates.size ].min
        (0...n).map do |i|
          { views: to_i(views[i]), at: dates[i] }
        end
      end

      def self.compute_metrics(subscribers, posts)
        view_values = posts.map { |p| p[:views] }.compact.reject(&:zero?)
        avg_views = view_values.any? ? (view_values.sum.to_f / view_values.size).round : nil
        {
          posts_on_page: posts.size,
          avg_views: avg_views,
          # «Просматриваемость» — avg views ÷ subscribers. The single strongest keyless real-audience
          # proxy (healthy TG 20-50%; <10% = views far below subscriber base → inflated followers).
          view_sub_ratio: (avg_views && subscribers&.positive? ? (avg_views.to_f / subscribers * 100).round(1) : nil),
          # Coefficient of variation of views — near-zero variance across posts reads as manufactured.
          view_cv: coefficient_of_variation(view_values),
          post_span_days: post_span_days(posts),
          median_gap_hours: median_gap_hours(posts)
        }
      end

      def self.coefficient_of_variation(values)
        return nil if values.size < 3

        mean = values.sum.to_f / values.size
        return nil if mean.zero?

        variance = values.sum { |v| (v - mean)**2 } / values.size
        (Math.sqrt(variance) / mean).round(3)
      end

      def self.post_span_days(posts)
        times = post_times(posts)
        return nil if times.size < 2

        ((times.max - times.min) / 86_400.0).round(1)
      end

      def self.median_gap_hours(posts)
        times = post_times(posts).sort
        return nil if times.size < 2

        gaps = times.each_cons(2).map { |a, b| (b - a) / 3600.0 }
        sorted = gaps.sort
        mid = sorted.size / 2
        median = sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
        median.round(1)
      end

      def self.post_times(posts)
        posts.filter_map { |p| Time.parse(p[:at]) if p[:at] }
      rescue ArgumentError
        []
      end

      # "236K" / "2.99M" / "1 234" / "1,234" → Integer.
      def self.to_i(raw)
        s = raw.to_s.strip.gsub(/[  , ]/, "")
        case s
        when /\A([\d.]+)K\z/i then ($1.to_f * 1_000).round
        when /\A([\d.]+)M\z/i then ($1.to_f * 1_000_000).round
        when /\A\d+\z/        then s.to_i
        end
      end
    end
  end
end
