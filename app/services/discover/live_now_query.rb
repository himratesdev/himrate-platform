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
  # No recommendations/ML here — the design's «Рекомендации» tab stays deferred.
  class LiveNowQuery
    LIMIT = 24
    RECENT_HOURS = 48 # a "live" row older than this is a ghost, not a stream

    def initialize(user:, limit: LIMIT)
      @user = user
      @limit = limit.to_i.clamp(1, 50)
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
        SELECT ranked.*
        FROM (
          SELECT DISTINCT ON (s.channel_id)
                 s.channel_id, s.game_name, s.started_at,
                 c.login, c.display_name,
                 ti.ccv, ti.erv, ti.authenticity, ti.band_row, ti.band_color,
                 ti.erv AS real_viewers
          FROM streams s
          JOIN channels c ON c.id = s.channel_id AND c.deleted_at IS NULL AND c.is_monitored = TRUE
          LEFT JOIN LATERAL (
            SELECT tih.ccv, tih.erv, tih.authenticity, tih.band_row, tih.band_color
            FROM trust_index_histories tih
            WHERE tih.channel_id = s.channel_id
              AND tih.engine_version = 'v2' AND tih.erv IS NOT NULL
            ORDER BY tih.calculated_at DESC
            LIMIT 1
          ) ti ON TRUE
          WHERE s.ended_at IS NULL AND s.started_at > :since
          ORDER BY s.channel_id, s.started_at DESC
        ) ranked
        ORDER BY ranked.real_viewers DESC NULLS LAST, ranked.channel_id ASC
        LIMIT :limit
      SQL
      ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql([ sql, { since: RECENT_HOURS.hours.ago, limit: @limit } ])
      ).to_a
    end

    def watched_ids
      return Set.new unless @user

      @user.tracked_channels.where(tracking_enabled: true).pluck(:channel_id).to_set
    end

    def build(row, watched)
      pct = row["authenticity"]&.to_f
      label, color = label_and_color(row)
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
        ti_score: pct&.round(1)
      }
    end

    # v2 rows carry no erv_label text — re-derive it from the persisted band_row via the canonical
    # BandClassifier map + band.<key> locale, resolved under the REQUEST locale. Returns [label, color].
    def label_and_color(row)
      key = TrustIndex::V2::BandClassifier.label_key_for(row["band_row"].to_i)
      [ I18n.t(key, default: nil), row["band_color"] ]
    end
  end
end
