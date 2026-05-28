# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-3 (FR-007 / M7): хронология subs/cheers/follows/hype из pva_engagement_events.
    # Опционально фильтр ?type=. {data, meta} (эталон OverviewService). Последние LIMIT событий.
    class EngagementLogService
      LIMIT = 100

      class InvalidType < StandardError; end

      def initialize(user:, type: nil)
        @user = user
        @type = type.presence
        raise InvalidType, "Unknown type '#{@type}'" if @type && !PvaEngagementEvent::EVENT_TYPES.include?(@type)
      end

      def call
        events = scoped.order(occurred_at: :desc).limit(LIMIT).to_a
        channels = Channel.where(twitch_id: events.map(&:twitch_channel_id).uniq).index_by(&:twitch_id)
        { data: { entries: events.map { |event| entry(event, channels[event.twitch_channel_id]) } },
          meta: { type: @type, count: events.size } }
      end

      private

      def scoped
        relation = PvaEngagementEvent.where(user_id: @user.id)
        @type ? relation.where(event_type: @type) : relation
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
