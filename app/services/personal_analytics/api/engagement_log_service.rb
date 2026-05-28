# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-3 (FR-007 / M7): хронология subs/cheers/follows/hype из pva_engagement_events.
    # Опционально фильтр ?type=. {data, meta} (эталон OverviewService). Последние LIMIT событий.
    class EngagementLogService
      LIMIT = 100

      class InvalidType < StandardError; end

      def initialize(user:, type: nil, before: nil)
        @user = user
        @type = type.presence
        @before = parse_time(before)
        raise InvalidType, "Unknown type '#{@type}'" if @type && !PvaEngagementEvent::EVENT_TYPES.include?(@type)
      end

      def call
        events = scoped.order(occurred_at: :desc).limit(LIMIT).to_a
        channels = Channel.where(twitch_id: events.map(&:twitch_channel_id).uniq).index_by(&:twitch_id)
        { data: { entries: events.map { |event| entry(event, channels[event.twitch_channel_id]) } },
          meta: { type: @type, count: events.size, next_cursor: next_cursor(events) } }
      end

      private

      # Курсор-пагинация: next_cursor = occurred_at последнего события при полной странице → FE передаёт
      # его как ?before= для следующей страницы (вся хронология достижима, не только последние LIMIT).
      def scoped
        relation = PvaEngagementEvent.where(user_id: @user.id)
        relation = relation.where(event_type: @type) if @type
        relation = relation.where(occurred_at: ...@before) if @before
        relation
      end

      def next_cursor(events)
        events.size == LIMIT ? events.last.occurred_at.iso8601 : nil
      end

      def parse_time(value)
        return nil if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def entry(event, channel)
        { type: event.event_type, twitch_channel_id: event.twitch_channel_id,
          login: channel&.login || event.twitch_login, display_name: channel&.display_name || event.twitch_login,
          avatar_url: channel&.profile_image_url, amount: event.amount, anonymous: event.anonymous,
          occurred_at: event.occurred_at.iso8601 }
      end
    end
  end
end
