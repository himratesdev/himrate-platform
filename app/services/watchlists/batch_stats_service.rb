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

      # Distribute per watchlist (PR3b: v2 → avg_authenticity, mirrors EnrichmentService#stats)
      wl_ids.to_h do |wl_id|
        ch_ids = wc_map[wl_id] || []
        base = {
          live_count: ch_ids.count { |cid| live_set.include?(cid) },
          tracked_count: ch_ids.count { |cid| tracked_set.include?(cid) },
          total: ch_ids.size
        }
        stats = if v2_engine?
          a_values = ch_ids.filter_map { |cid| ti_map[cid]&.authenticity&.to_f }
          base.merge(avg_authenticity: a_values.any? ? (a_values.sum / a_values.size).round(1) : nil)
        else
          erv_values = ch_ids.filter_map { |cid| ti_map[cid]&.erv_percent&.to_f }
          base.merge(avg_erv: erv_values.any? ? (erv_values.sum / erv_values.size).round(1) : nil)
        end
        [ wl_id, stats ]
      end
    end

    private

    def empty_stats_for(wl_ids)
      empty = if v2_engine?
        { avg_authenticity: nil, live_count: 0, tracked_count: 0, total: 0 }
      else
        { avg_erv: nil, live_count: 0, tracked_count: 0, total: 0 }
      end
      wl_ids.to_h { |id| [ id, empty ] }
    end

    # CR #425 N-4 + CR #427 Nit-1: SELECT only what this service reads — stats are aggregate-only
    # (v2 reads authenticity, v1 reads erv_percent; channel_id/calculated_at drive DISTINCT ON).
    # The per-row label contract lives in EnrichmentService, not here.
    def latest_ti_for_channels(channel_ids)
      if v2_engine?
        TrustIndexHistory
          .where(channel_id: channel_ids, engine_version: "v2")
          .select("DISTINCT ON (channel_id) channel_id, authenticity, calculated_at")
          .order(:channel_id, calculated_at: :desc)
          .index_by(&:channel_id)
      else
        TrustIndexHistory
          .where(channel_id: channel_ids, engine_version: "v1")
          .select("DISTINCT ON (channel_id) channel_id, erv_percent, calculated_at")
          .order(:channel_id, calculated_at: :desc)
          .index_by(&:channel_id)
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
