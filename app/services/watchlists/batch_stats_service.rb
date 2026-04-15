# frozen_string_literal: true

# TASK-036: Batch stats for all user's watchlists in one pass.
# Instead of N × 4 queries (per-watchlist), does 4 queries total.
module Watchlists
  class BatchStatsService
    def initialize(watchlists:, user:)
      @watchlists = watchlists
      @user = user
    end

    # Returns { watchlist_id => { avg_erv:, live_count:, tracked_count:, total: } }
    def call
      return {} if @watchlists.empty?

      wl_ids = @watchlists.map(&:id)

      # 1 query: all channel_ids grouped by watchlist
      wc_map = WatchlistChannel
        .where(watchlist_id: wl_ids)
        .pluck(:watchlist_id, :channel_id)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }

      all_channel_ids = wc_map.values.flatten.uniq
      return empty_stats_for(wl_ids) if all_channel_ids.empty?

      # 3 batch queries for ALL channels across ALL watchlists
      ti_map = latest_ti_for_channels(all_channel_ids)
      live_set = live_channel_ids(all_channel_ids)
      tracked_set = tracked_channel_ids(all_channel_ids)

      # Distribute per watchlist
      wl_ids.to_h do |wl_id|
        ch_ids = wc_map[wl_id] || []
        erv_values = ch_ids.filter_map { |cid| ti_map[cid]&.erv_percent&.to_f }

        stats = {
          avg_erv: erv_values.any? ? (erv_values.sum / erv_values.size).round(1) : nil,
          live_count: ch_ids.count { |cid| live_set.include?(cid) },
          tracked_count: ch_ids.count { |cid| tracked_set.include?(cid) },
          total: ch_ids.size
        }
        [ wl_id, stats ]
      end
    end

    private

    def empty_stats_for(wl_ids)
      empty = { avg_erv: nil, live_count: 0, tracked_count: 0, total: 0 }
      wl_ids.to_h { |id| [ id, empty ] }
    end

    def latest_ti_for_channels(channel_ids)
      TrustIndexHistory
        .where(channel_id: channel_ids)
        .select("DISTINCT ON (channel_id) channel_id, trust_index_score, erv_percent, ccv, calculated_at")
        .order(:channel_id, calculated_at: :desc)
        .index_by(&:channel_id)
    end

    def live_channel_ids(channel_ids)
      Stream.where(channel_id: channel_ids, ended_at: nil).pluck(:channel_id).to_set
    end

    def tracked_channel_ids(channel_ids)
      TrackedChannel
        .where(user: @user, channel_id: channel_ids, tracking_enabled: true)
        .pluck(:channel_id)
        .to_set
    end
  end
end
