# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-3 (FR-006 / M6 Communities): «Мои сообщества» из pva_chat_activities. Per канал:
    # activity_level (high/mid/low/min из суммарного message_count за окно) + top_emotes (из emote_counts).
    # {data, meta} (эталон OverviewService). Все периоды бесплатны (PVA all-free).
    class CommunitiesService
      VALID_WINDOWS = %w[7d 30d 90d 365d all].freeze
      DEFAULT_WINDOW = "30d"
      WINDOW_DAYS = { "7d" => 7, "30d" => 30, "90d" => 90, "365d" => 365, "all" => nil }.freeze
      TOP_EMOTES = 5
      LEVELS = [ [ 500, "high" ], [ 100, "mid" ], [ 20, "low" ] ].freeze

      class InvalidWindow < StandardError; end

      def initialize(user:, window: nil)
        @user = user
        @window = window.presence || DEFAULT_WINDOW
        raise InvalidWindow, "Unknown window '#{@window}'" unless VALID_WINDOWS.include?(@window)
      end

      def call
        aggregated = aggregate
        return { data: { communities: [] }, meta: meta } if aggregated.empty?

        channels = Channel.where(twitch_id: aggregated.keys).index_by(&:twitch_id)
        communities = aggregated.map { |tcid, agg| community(tcid, agg, channels[tcid]) }
        { data: { communities: communities }, meta: meta }
      end

      private

      # {twitch_channel_id => {message_count, emote_counts(merged), login}} desc by message_count.
      def aggregate
        agg = Hash.new { |hash, key| hash[key] = { message_count: 0, emote_counts: Hash.new(0), login: nil } }
        scoped.pluck(:twitch_channel_id, :message_count, :emote_counts, :twitch_login).each do |tcid, count, emotes, login|
          row = agg[tcid]
          row[:message_count] += count
          row[:login] ||= login
          emotes.each { |emote, num| row[:emote_counts][emote] += num }
        end
        agg.sort_by { |_, row| -row[:message_count] }.to_h
      end

      def scoped
        from, to = range
        relation = PvaChatActivity.where(user_id: @user.id)
        from ? relation.where(date: from..to) : relation.where(date: ..to)
      end

      def community(tcid, agg, channel)
        { twitch_channel_id: tcid, login: channel&.login || agg[:login],
          display_name: channel&.display_name || agg[:login], avatar_url: channel&.profile_image_url,
          message_count: agg[:message_count], activity_level: level_for(agg[:message_count]),
          top_emotes: top_emotes(agg[:emote_counts]) }
      end

      def level_for(count)
        LEVELS.each { |threshold, level| return level if count >= threshold }
        "min"
      end

      def top_emotes(counts)
        counts.sort_by { |_, num| -num }.first(TOP_EMOTES).map { |emote, num| { emote: emote, count: num } }
      end

      def range
        to = Time.current.to_date
        days = WINDOW_DAYS[@window]
        [ days && (to - days + 1), to ]
      end

      def meta
        { window: @window, generated_at: Time.current.iso8601 }
      end
    end
  end
end
