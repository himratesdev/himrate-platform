# frozen_string_literal: true

module Me
  # Channels in the viewer's watchlists that are currently live (screen 01 "Сейчас в эфире").
  # Live = has a Stream with ended_at IS NULL — the same definition as ChannelBlueprint#is_live and
  # Watchlists::BatchStatsService#live_channel_ids (kept in sync, not divergent). Preloads TI +
  # streams for N+1-free headline rendering.
  class LiveChannelsQuery
    def initialize(user)
      @user = user
    end

    def call
      channel_ids = WatchlistChannel.joins(:watchlist)
                                    .where(watchlists: { user_id: @user.id })
                                    .distinct.pluck(:channel_id)
      return [] if channel_ids.empty?

      live_ids = Stream.where(channel_id: channel_ids, ended_at: nil).distinct.pluck(:channel_id)
      return [] if live_ids.empty?

      Channel.where(id: live_ids).includes(:trust_index_histories, :streams).to_a
    end
  end
end
