# frozen_string_literal: true

module SocialAnalytics
  module Attribution
    # Descriptive Twitch → socials funnel (value-roadmap C2). Overlays a streamer's Twitch broadcast
    # timeline on their social activity/growth and surfaces temporal co-occurrences — a social spike
    # that FOLLOWS a stream. HONEST framing: temporal correlation, NOT causation. We are not
    # owner-connected, so we cannot attribute causally; the uplift could have other drivers. This is a
    # growth lens, NOT a fraud verdict (PO 2026-07-21: no накрутка analysis on socials).
    #
    # Pure PG + already-warmed cache read: streams + snapshots from PG, Telegram posts from the cached
    # StreamerSocialProfile → Puma-safe, no external I/O. The underlying social data is warmed by
    # ProfileRefreshWorker via the social endpoint; attribution just correlates it against streams.
    #
    # Two signals, different maturities:
    #   - Telegram per-post ({views, timestamp}) — works NOW (public posts carry both).
    #   - Snapshot subscriber growth vs stream cadence — VALUE GROWS as the time series accumulates
    #     (snapshots started 2026-07-21). Honestly labelled "building" until enough intervals exist.
    class StreamerFunnel
      WINDOW = 90.days          # lookback for streams + snapshots
      UPLIFT_WINDOW = 36.hours  # a social spike "follows" a stream if it lands within this window after
      SPIKE_FACTOR = 1.3        # a datapoint is a spike when >= this multiple of the baseline (median)
      SNAPSHOT_PLATFORMS = %w[telegram youtube].freeze
      FULL_COVERAGE_INTERVALS = 6 # snapshot intervals needed before growth coverage is "full"

      # temporal correlation, NOT causation — the honesty guarantee. Surfaced in the payload so any
      # consumer (future UI) can't present this as proof of a causal Twitch→social lift.
      DISCLAIMER = "Показаны совпадения во времени между эфирами и активностью в соцсетях. " \
                   "Это временная корреляция, а не доказательство причинно-следственной связи — " \
                   "рост мог быть вызван и другими факторами."

      def self.call(login, profile:)
        new(login, profile: profile).call
      end

      def initialize(login, profile:)
        @login = login.to_s.strip.downcase
        @profile = profile.is_a?(Hash) ? profile : {}
      end

      def call
        stream_starts = recent_stream_starts
        {
          login: @login,
          window_days: (WINDOW / 1.day).to_i,
          streams_in_window: stream_starts.size,
          last_stream_at: stream_starts.last&.iso8601,
          telegram: telegram_attribution(stream_starts),
          subscriber_growth: subscriber_growth(stream_starts),
          disclaimer: DISCLAIMER
        }
      end

      private

      def recent_stream_starts
        channel = Channel.find_by(login: @login)
        return [] unless channel

        channel.streams.where(started_at: WINDOW.ago..).order(:started_at).filter_map(&:started_at)
      end

      # Per-post Telegram correlation — available NOW. For each dated post, find the most recent stream
      # that started within UPLIFT_WINDOW before it; mark the post a "spike" when its views clear
      # SPIKE_FACTOR × the channel's median post views.
      def telegram_attribution(stream_starts)
        tg = @profile.dig(:platforms, :telegram)
        return { available: false } unless tg.is_a?(Hash) && tg[:available]

        posts = Array(tg[:recent_posts]).filter_map do |p|
          at = parse_time(p[:at])
          at && p[:views] ? { at: at, views: p[:views].to_i } : nil
        end
        return { available: false, reason: "no_dated_posts" } if posts.empty?

        median = median(posts.map { |p| p[:views] }.reject(&:zero?))
        correlated = posts.filter_map { |post| correlate_post(post, stream_starts, median) }

        {
          available: true,
          posts_analyzed: posts.size,
          median_views: median,
          stream_associated_posts: correlated,
          stream_associated_post_count: correlated.size,
          stream_associated_spikes: correlated.count { |c| c[:is_spike] }
        }
      end

      def correlate_post(post, stream_starts, median)
        preceding = stream_starts.select { |s| s <= post[:at] && s >= post[:at] - UPLIFT_WINDOW }.max
        return nil unless preceding

        ratio = median&.positive? ? (post[:views].to_f / median).round(2) : nil
        {
          post_at: post[:at].iso8601,
          views: post[:views],
          uplift_ratio: ratio,
          is_spike: ratio ? ratio >= SPIKE_FACTOR : false,
          preceding_stream_at: preceding.iso8601,
          hours_after_stream: ((post[:at] - preceding) / 1.hour).round(1)
        }
      end

      # Snapshot-based subscriber growth vs stream cadence — value GROWS as the time series accumulates.
      # For each consecutive snapshot pair: the subscriber delta and how many streams fell in that
      # interval. With enough intervals of each kind, compare average per-day growth of stream-covered
      # vs stream-free intervals (descriptive only — never a causal claim).
      def subscriber_growth(stream_starts)
        SNAPSHOT_PLATFORMS.each_with_object({}) do |platform, acc|
          snaps = SocialProfileSnapshot.for_login(@login).on_platform(platform)
                                       .where(captured_at: WINDOW.ago..)
                                       .where.not(subscribers: nil)
                                       .order(:captured_at).to_a
          result = growth_intervals(snaps, stream_starts)
          acc[platform] = result if result
        end
      end

      def growth_intervals(snaps, stream_starts)
        return nil if snaps.size < 2

        intervals = snaps.each_cons(2).map { |a, b| interval(a, b, stream_starts) }
        covered = intervals.select { |i| i[:streams].positive? && i[:days].positive? }
        free    = intervals.select { |i| i[:streams].zero? && i[:days].positive? }

        {
          coverage: intervals.size >= FULL_COVERAGE_INTERVALS ? "full" : "building",
          intervals: intervals,
          stream_covered_daily_growth: avg_daily_growth(covered),
          stream_free_daily_growth: avg_daily_growth(free)
        }
      end

      def interval(earlier, later, stream_starts)
        days = ((later.captured_at - earlier.captured_at) / 1.day).round(2)
        {
          from: earlier.captured_at.iso8601,
          to: later.captured_at.iso8601,
          delta: later.subscribers - earlier.subscribers,
          days: days,
          streams: stream_starts.count { |s| s > earlier.captured_at && s <= later.captured_at }
        }
      end

      def avg_daily_growth(intervals)
        return nil if intervals.empty?

        (intervals.sum { |i| i[:delta] / i[:days] } / intervals.size).round(1)
      end

      def parse_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def median(values)
        return nil if values.empty?

        sorted = values.sort
        mid = sorted.size / 2
        sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
      end
    end
  end
end
