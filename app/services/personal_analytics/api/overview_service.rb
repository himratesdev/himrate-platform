# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-2 (FR-001..005, M1-M5): /api/v1/me/analytics/overview payload из pva_view_rollups
    # (через ViewRollupSource — CH-agnostic read). Эталон Trends::Api::BaseEndpointService: #call →
    # { data:, meta: }. Все периоды бесплатны (нет window-locks, PVA all-free). Cold-start → hero: nil.
    class OverviewService
      VALID_WINDOWS = %w[7d 30d 90d 365d all].freeze
      DEFAULT_WINDOW = "30d"
      WINDOW_DAYS = { "7d" => 7, "30d" => 30, "90d" => 90, "365d" => 365, "all" => nil }.freeze
      TOP_CHANNELS_LIMIT = 10
      DISCOVERY_DAYS = 7

      class InvalidWindow < StandardError; end

      def initialize(user:, window: nil)
        @user = user
        @window = window.presence || DEFAULT_WINDOW
        raise InvalidWindow, "Unknown window '#{@window}'" unless VALID_WINDOWS.include?(@window)
      end

      def call
        total = source.total_seconds
        return cold_payload if total.zero?

        { data: { hero: hero(total), top_streamers: top_streamers, categories: categories(total),
                  heatmap: { matrix: source.heatmap }, discovery: discovery },
          meta: meta(cold_start: false) }
      end

      private

      def source
        @source ||= begin
          from, to = range
          PersonalAnalytics::Aggregates::ViewRollupSource.new(@user.id, from, to)
        end
      end

      def range
        to = Time.current.to_date
        days = WINDOW_DAYS[@window]
        [ days && (to - days + 1), to ]
      end

      def hero(total)
        { seconds: total, delta_seconds: delta(total),
          sparkline: source.daily_seconds.sort.map { |date, secs| { date: date.iso8601, seconds: secs } },
          devices: source.device_seconds.sort_by { |_, secs| -secs }.map { |name, secs| { name: name, seconds: secs } } }
      end

      # delta = текущее окно − предыдущее равное окно. Для all-time нет предыдущего → nil.
      def delta(total)
        days = WINDOW_DAYS[@window]
        return nil if days.nil?

        to = Time.current.to_date
        prev = PersonalAnalytics::Aggregates::ViewRollupSource.new(@user.id, to - (days * 2) + 1, to - days)
        total - prev.total_seconds
      end

      def top_streamers
        rows = source.top_channels(TOP_CHANNELS_LIMIT)
        channels = Channel.where(twitch_id: rows.map { |r| r[:twitch_channel_id] }).index_by(&:twitch_id)
        ti_scores = ti_scores_for(channels.values.map(&:id))
        rows.map { |row| enrich_channel(row, channels, ti_scores) }
      end

      def enrich_channel(row, channels, ti_scores)
        channel = channels[row[:twitch_channel_id]]
        { twitch_channel_id: row[:twitch_channel_id],
          login: channel&.login || row[:twitch_login], display_name: channel&.display_name || row[:twitch_login],
          avatar_url: channel&.profile_image_url, seconds: row[:seconds], sessions: row[:sessions],
          last_seen: row[:last_seen_at]&.iso8601,
          # PR3b: ti_score kept for the current PVA frontend (nil under v2 — additive transition);
          # authenticity = the v2 scalar (same 0-100). Frontend migrates to authenticity in its own PR.
          ti_score: (channel && !v2_engine?) ? ti_scores[channel.id]&.to_f : nil,
          authenticity: (channel && v2_engine?) ? ti_scores[channel.id]&.to_f : nil }
      end

      # Latest trust scalar per channel одним запросом (DISTINCT ON), без N+1. Engine-aware (PR3b).
      def ti_scores_for(channel_ids)
        return {} if channel_ids.empty?

        if v2_engine?
          TrustIndexHistory.where(channel_id: channel_ids, engine_version: "v2")
                           .order(:channel_id, calculated_at: :desc)
                           .select("DISTINCT ON (channel_id) channel_id, authenticity")
                           .to_h { |tih| [ tih.channel_id, tih.authenticity ] }
        else
          TrustIndexHistory.where(channel_id: channel_ids, engine_version: "v1")
                           .order(:channel_id, calculated_at: :desc)
                           .select("DISTINCT ON (channel_id) channel_id, trust_index_score")
                           .to_h { |tih| [ tih.channel_id, tih.trust_index_score ] }
        end
      end

      def v2_engine?
        return @v2_engine if defined?(@v2_engine)

        @v2_engine =
          begin
            Flipper.enabled?(:ti_v2_engine)
          rescue StandardError
            false
          end
      end

      def categories(total)
        source.category_seconds.sort_by { |_, secs| -secs }.map do |game_id, secs|
          { game_id: game_id, name: game_id.presence || "unknown",
            seconds: secs, pct: (secs.to_f / total * 100).round(1) }
        end
      end

      def discovery
        source.newly_discovered(DISCOVERY_DAYS).map do |entry|
          { twitch_channel_id: entry[:twitch_channel_id], login: entry[:twitch_login],
            first_seen: entry[:first_seen_at]&.iso8601,
            still_watching: entry[:last_seen_at].present? && entry[:last_seen_at] >= DISCOVERY_DAYS.days.ago }
        end
      end

      def cold_payload
        { data: { hero: nil, top_streamers: [], categories: [], heatmap: { matrix: [] }, discovery: [] },
          meta: meta(cold_start: true) }
      end

      def meta(cold_start:)
        { window: @window, cold_start: cold_start, generated_at: Time.current.iso8601 }
      end
    end
  end
end
