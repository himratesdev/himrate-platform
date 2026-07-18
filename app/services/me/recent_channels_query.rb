# frozen_string_literal: true

module Me
  # Viewer's recently-opened channels (screen 01 "Недавно открытые каналы"), newest first, capped.
  # recent_channels is already one row per channel (unique index), so opened_at DESC is distinct.
  # Preloads TI + streams so ChannelBlueprint headline rendering is N+1-free, preserving order.
  class RecentChannelsQuery
    LIMIT = 10

    def initialize(user)
      @user = user
    end

    def call
      ordered_ids = @user.recent_channels.order(opened_at: :desc).limit(LIMIT).pluck(:channel_id)
      return [] if ordered_ids.empty?

      by_id = Channel.where(id: ordered_ids)
                     .includes(:trust_index_histories, :streams)
                     .index_by(&:id)
      ordered_ids.filter_map { |id| by_id[id] }
    end
  end
end
