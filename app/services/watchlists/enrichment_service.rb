# frozen_string_literal: true

# TASK-036 FR-008: Enriched channel list for watchlist.
# Single query with joins — no N+1. Returns channel data with ERV%, TI, CCV,
# is_live, freshness, inactive status, tracked state, tags, notes.
module Watchlists
  class EnrichmentService
    def initialize(watchlist:, user:, filters: {}, sort: "erv_desc")
      @watchlist = watchlist
      @user = user
      @filters = filters
      @sort = sort
    end

    def call
      wc_scope = @watchlist.watchlist_channels.ordered
      channels = load_enriched_channels(wc_scope)
      channels = apply_filters(channels)
      channels = apply_sort(channels)
      channels
    end

    # FR-023: Aggregate stats for the watchlist.
    # Aggregate = avg_authenticity (0-100, scale-safe to average — raw erv COUNTS across
    # channels of different V are not); v1 avg_erv retired (T2 reads avg_authenticity).
    def stats
      wc_ids = @watchlist.watchlist_channels.pluck(:channel_id)
      return { avg_authenticity: nil, live_count: 0, tracked_count: 0, total: 0 } if wc_ids.empty?

      latest_ti = latest_ti_for_channels(wc_ids)
      live_ids = live_channel_ids(wc_ids)
      tracked_ids = tracked_channel_ids(wc_ids)

      base = { live_count: live_ids.size, tracked_count: tracked_ids.size, total: wc_ids.size }

      a_values = latest_ti.filter_map { |_id, ti| ti&.authenticity&.to_f }
      base.merge(avg_authenticity: a_values.any? ? (a_values.sum / a_values.size).round(1) : nil)
    end

    private

    def load_enriched_channels(wc_scope)
      wc_records = wc_scope.includes(:channel).to_a
      channel_ids = wc_records.map(&:channel_id)
      return [] if channel_ids.empty?

      ti_map = latest_ti_for_channels(channel_ids)
      live_ids = live_channel_ids(channel_ids)
      tracked_ids = tracked_channel_ids(channel_ids)
      tags_notes_map = tags_notes_for_watchlist(channel_ids)
      last_stream_map = last_stream_for_channels(channel_ids)

      wc_records.map do |wc|
        ch = wc.channel
        ti = ti_map[ch.id]
        tn = tags_notes_map[ch.id]
        last_stream_at = last_stream_map[ch.id]

        build_enriched(ch, ti, wc, tn, live_ids, tracked_ids, last_stream_at)
      end
    end

    def build_enriched(channel, ti, wc, tags_note, live_ids, tracked_ids, last_stream_at)
      base = {
        channel_id: channel.id,
        login: channel.login,
        display_name: channel.display_name,
        avatar_url: channel.profile_image_url,
        ccv: ti&.ccv&.to_i,
        is_live: live_ids.include?(channel.id),
        is_tracked: tracked_ids.include?(channel.id),
        last_stream_at: last_stream_at&.iso8601,
        inactive: inactive?(last_stream_at),
        tags: tags_note&.tags || [],
        notes: tags_note&.notes,
        added_at: wc.added_at.iso8601,
        position: wc.position
      }

      # PR3b (T2 contract, api.ts WatchlistChannel): erv COUNT + authenticity + engine-emitted
      # band_color (5 values red/yellow/amber/green/grey — reader-side thresholds retired).
      # last_ti_at → last_calculated_at (T2 rename).
      # CR SF-3 follow-up: band_color alone cannot distinguish row 3 «Аудитория реальная» from
      # row 4 «Аномалий не замечено» (both green) — emit band_row + the canonical label_key
      # (BandClassifier::LABEL_KEYS_BY_ROW) so watchlist rows render the exact band label
      # without re-deriving thresholds client-side.
      base.merge(
        erv: ti&.erv,
        authenticity: ti&.authenticity&.to_f&.round(1),
        band_row: ti&.band_row,
        label_key: TrustIndex::V2::BandClassifier.label_key_for(ti&.band_row),
        band_color: ti&.band_color || "grey",
        last_calculated_at: ti&.calculated_at&.iso8601
      )
    end

    # FR-026: Freshness — computed client-side from last_ti_at
    # FR-028: Inactive — >30 days since last stream
    def inactive?(last_stream_at)
      return true if last_stream_at.nil?

      last_stream_at < 30.days.ago
    end

    # Single query: DISTINCT ON per channel, latest v2 TI record.
    def latest_ti_for_channels(channel_ids)
      TrustIndexHistory
        .where(channel_id: channel_ids, engine_version: "v2")
        .select("DISTINCT ON (channel_id) channel_id, erv, authenticity, band_row, band_color, ccv, calculated_at")
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

    def tags_notes_for_watchlist(channel_ids)
      WatchlistTagsNote
        .where(watchlist: @watchlist, channel_id: channel_ids)
        .index_by(&:channel_id)
    end

    def last_stream_for_channels(channel_ids)
      Stream
        .where(channel_id: channel_ids)
        .where.not(ended_at: nil)
        .group(:channel_id)
        .maximum(:ended_at)
    end

    # FR-010: Server-side filters (Premium/Business only — enforced by policy).
    # PR3b: param NAMES survive (no active client sends filters); under v2 erv_min/erv_max/ti_min
    # all reinterpret on the authenticity 0-100 scale (scale continuity — raw erv counts are
    # V-dependent and unusable as a threshold).
    def apply_filters(channels)
      metric = :authenticity
      ti_metric = :authenticity
      channels = channels.select { |c| c[metric].to_f >= @filters[:erv_min].to_f } if @filters[:erv_min].present?
      channels = channels.select { |c| c[metric].to_f <= @filters[:erv_max].to_f } if @filters[:erv_max].present?
      channels = channels.select { |c| c[ti_metric].to_f >= @filters[:ti_min].to_f } if @filters[:ti_min].present?
      channels = channels.select { |c| c[:is_live] == true } if @filters[:is_live] == "true"
      channels = channels.reject { |c| c[:is_live] } if @filters[:is_live] == "false"
      channels
    end

    # FR-010: Sort options. erv sorts use the v2 count; ti_desc aliases to authenticity
    # (graceful for stale senders — T2 retired it); "added_desc" added as an alias —
    # the live T2 build sends it while the backend only knew "added_at_desc" (silent no-sort bug).
    def apply_sort(channels)
      erv_key = :erv
      ti_key = :authenticity
      case @sort
      when "erv_desc" then channels.sort_by { |c| -(c[erv_key] || 0) }
      when "erv_asc" then channels.sort_by { |c| c[erv_key] || 0 }
      when "ti_desc" then channels.sort_by { |c| -(c[ti_key] || 0) }
      when "ccv_desc" then channels.sort_by { |c| -(c[:ccv] || 0) }
      when "name_asc" then channels.sort_by { |c| c[:display_name].to_s.downcase }
      when "added_at_desc", "added_desc" then channels.sort_by { |c| c[:added_at] }.reverse
      else channels
      end
    end
  end
end
