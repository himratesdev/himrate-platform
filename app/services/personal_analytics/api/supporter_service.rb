# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-3 (FR-008 / M9 «Моё место у каналов» + свёрнутый M8 tenure): per-канал АБСОЛЮТНЫЙ
    # категориальный tier (из pva_supporter_status) + точный tenure (из channel_tenure). {data, meta}.
    # composite_score НЕ exposed (internal-only, BR-006 — в UI только категория, не число).
    class SupporterService
      def initialize(user:)
        @user = user
      end

      def call
        statuses = PvaSupporterStatus.where(user_id: @user.id).to_a
        return { data: { supporters: [] }, meta: meta } if statuses.empty?

        channels = Channel.where(twitch_id: statuses.map(&:twitch_channel_id)).index_by(&:twitch_id)
        tenures = ChannelTenure.where(user_id: @user.id).index_by(&:twitch_channel_id)
        supporters = statuses.map { |status| supporter(status, channels[status.twitch_channel_id], tenures) }
        { data: { supporters: supporters }, meta: meta }
      end

      private

      def supporter(status, channel, tenures)
        tenure = tenures[status.twitch_channel_id]
        { twitch_channel_id: status.twitch_channel_id, tier: status.tier,
          login: channel&.login || status.twitch_login, display_name: channel&.display_name || status.twitch_login,
          avatar_url: channel&.profile_image_url, tenure_months: tenure&.months, sub_tier: tenure&.sub_tier,
          computed_at: status.computed_at.iso8601 }
      end

      def meta
        { generated_at: Time.current.iso8601 }
      end
    end
  end
end
