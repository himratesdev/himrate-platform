# frozen_string_literal: true

module Discover
  # Screen 04 «Куда пойти» — live-now channels ranked by REAL audience (latest TIH), the same honest
  # metric the public card / brand search use. Open to guests (user: nil); the only per-user field,
  # is_watched_by_user, is false for a guest by construction. Compute-on-read, no schema.
  #
  # V1-RETIRE (2026-09-02): v2-only — real = native `erv` count, % = `authenticity`, label from
  # band_row via BandClassifier. Wire keys `erv_percent`/`ti_score` KEPT as legacy names carrying
  # authenticity (landing/discover.js reads them; renaming the wire is a separate task).
  #
  # Scale (fixed after a live 504 on staging, 2026-07-20): the naive `ended_at IS NULL → .to_a`
  # materialized EVERY live+ghost stream row in Ruby — unbounded (ghost never-closed rows are a
  # known reality, see Streams::LifecycleAudit). Now the ENTIRE ranking runs in ONE SQL query:
  #   - live rows bounded to the last RECENT_HOURS (kills ancient ghosts; index-served by the
  #     partial idx_streams_active_started_at),
  #   - DISTINCT ON (channel_id) dedups stale duplicates per channel,
  #   - LATERAL latest-TIH lookup per live channel (index-served by (channel_id, calculated_at)),
  #   - ORDER BY real DESC + LIMIT in PG — nothing unbounded ever reaches Ruby.
  #
  # Filters (WEB-CONSOLIDATION home board; before this every param but `limit` was silently
  # dropped — `?game=Dota 2` answered 50 rows across 18 games):
  #   game         — exact category name of the CURRENT broadcast, case-insensitive
  #   language     — broadcast language code ("ru", "en", …), case-insensitive
  #   band         — comma-separated verdict colours (BAND_COLORS); a channel with no v2 verdict yet
  #                  counts as "grey", the colour its «Недостаточно данных» label already carries
  #   min_viewers / max_viewers — inclusive bounds on the REAL audience (the ranking key); a channel
  #                  with no verdict has no real audience and never satisfies a bound
  # Unknown / malformed values are ignored (an unfiltered board, never a 400) — this is a browse
  # surface. Where they apply: game/language on the DEDUPED current-broadcast row (filtering before
  # DISTINCT ON would let a stale ghost duplicate in another category stand in for the channel), and
  # before the LATERAL, so a filtered request only runs the TIH lookup for channels that passed.
  # Verdict/audience bounds need the LATERAL row and apply after it. Every filter works on the
  # already-bounded live set (at most one row per live channel) — none can widen the scan of
  # `streams` or `trust_index_histories`.
  # No recommendations/ML here — the design's «Рекомендации» tab stays deferred.
  class LiveNowQuery
    LIMIT = 24
    RECENT_HOURS = 48 # a "live" row older than this is a ghost, not a stream
    # Every colour TrustIndex::V2::BandClassifier can persist on a v2 row.
    BAND_COLORS = %w[green amber yellow red grey].freeze

    def initialize(user:, limit: LIMIT, filters: {})
      @user = user
      @limit = limit.to_i.clamp(1, 50)
      @game = filters[:game].to_s.strip.presence
      @language = filters[:language].to_s.strip.presence
      @bands = filters[:band].to_s.split(",").map { |b| b.strip.downcase }
                             .select { |b| BAND_COLORS.include?(b) }.uniq.presence
      @min_viewers = non_negative_int(filters[:min_viewers])
      @max_viewers = non_negative_int(filters[:max_viewers])
    end

    def call
      rows = select_rows
      return [] if rows.empty?

      watched = watched_ids
      rows.map { |row| build(row, watched) }
    end

    private

    def select_rows
      sql = <<~SQL
        SELECT live.channel_id, live.game_name, live.started_at, live.login, live.display_name,
               ti.ccv, ti.authenticity, ti.band_row, ti.band_color,
               ti.erv AS real_viewers
        FROM (
          SELECT DISTINCT ON (s.channel_id)
                 s.channel_id, s.game_name, s.language, s.started_at,
                 c.login, c.display_name
          FROM streams s
          JOIN channels c ON c.id = s.channel_id AND c.deleted_at IS NULL AND c.is_monitored = TRUE
          WHERE s.ended_at IS NULL AND s.started_at > :since
          ORDER BY s.channel_id, s.started_at DESC
        ) live
        LEFT JOIN LATERAL (
          SELECT tih.ccv, tih.erv, tih.authenticity, tih.band_row, tih.band_color
          FROM trust_index_histories tih
          WHERE tih.channel_id = live.channel_id
            AND tih.engine_version = 'v2' AND tih.erv IS NOT NULL
          ORDER BY tih.calculated_at DESC
          LIMIT 1
        ) ti ON TRUE
        #{filter_clause}
        ORDER BY ti.erv DESC NULLS LAST, live.channel_id ASC
        LIMIT :limit
      SQL
      binds = { since: RECENT_HOURS.hours.ago, limit: @limit, game: @game, language: @language,
                bands: @bands, min_viewers: @min_viewers, max_viewers: @max_viewers }
      ActiveRecord::Base.connection.select_all(ActiveRecord::Base.sanitize_sql([ sql, binds ])).to_a
    end

    # Fixed SQL fragments only — every value travels as a named bind.
    def filter_clause
      conditions = []
      conditions << "LOWER(live.game_name) = LOWER(:game)" if @game
      conditions << "LOWER(live.language) = LOWER(:language)" if @language
      conditions << "COALESCE(ti.band_color, 'grey') IN (:bands)" if @bands
      conditions << "ti.erv >= :min_viewers" if @min_viewers
      conditions << "ti.erv <= :max_viewers" if @max_viewers
      conditions.empty? ? "" : "WHERE #{conditions.join(' AND ')}"
    end

    def non_negative_int(value)
      n = Integer(value.to_s, 10, exception: false)
      n if n && n >= 0
    end

    def watched_ids
      return Set.new unless @user

      @user.tracked_channels.where(tracking_enabled: true).pluck(:channel_id).to_set
    end

    def build(row, watched)
      pct = row["authenticity"]&.to_f
      label, color, tooltip = verdict_copy(row)
      started_at = row["started_at"]
      {
        login: row["login"],
        display_name: row["display_name"],
        game_name: row["game_name"],
        started_at: started_at.respond_to?(:iso8601) ? started_at.iso8601 : started_at&.to_s,
        is_watched_by_user: watched.include?(row["channel_id"]),
        shown_viewers: row["ccv"].to_i.positive? ? row["ccv"].to_i : nil,
        real_viewers: row["real_viewers"]&.to_i,
        erv_percent: pct&.round(1),
        erv_label: label,
        erv_label_color: color,
        erv_tooltip: tooltip,
        ti_score: pct&.round(1)
      }
    end

    # v2 rows carry no erv_label text — re-derive it from the persisted band_row via the canonical
    # BandClassifier maps + band.<key> locale, resolved under the REQUEST locale. erv_tooltip is the
    # scale hint that belongs with the label (band.tooltip.*) — a board of six verdicts is unreadable
    # without it, and the key alone was all a web client ever got. Returns [label, color, tooltip].
    def verdict_copy(row)
      band_row = row["band_row"].to_i
      [ I18n.t(TrustIndex::V2::BandClassifier.label_key_for(band_row), default: nil),
        row["band_color"],
        I18n.t(TrustIndex::V2::BandClassifier.tooltip_key_for(band_row), default: nil) ]
    end
  end
end
