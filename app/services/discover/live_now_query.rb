# frozen_string_literal: true

module Discover
  # Screen 04 «Куда пойти» — live-now channels ranked by REAL audience (latest TIH), the same honest
  # metric the public card / brand search use. Viewer-free (any signed-in user, access-model v2).
  # Compute-on-read, no schema.
  #
  # TI-v2 engine-aware (2026-07-21): after the ti_v2 cutover (PR3b) the TIH row shape changed —
  # v2 rows carry the NATIVE subtracted real-viewer count `erv` + `authenticity` (% real) + `band_*`
  # and leave the retired `erv_percent`/`trust_index_score` NULL (see V2::Persistence). This query
  # used to read only the v1 columns off the latest row, so post-cutover it returned NULL audience
  # for every live channel. Now it reads BOTH shapes per row (mirrors Trends::Api::ErvEndpointService):
  # v2 → real = erv, % = authenticity, label from band_row via BandClassifier::LABEL_KEYS_BY_ROW;
  # v1 → real = ccv × erv%/100, label via ErvCalculator (transition-window legacy rows). The output
  # contract is unchanged (real_viewers/erv_percent/erv_label/…) — no frontend change needed.
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
                 ti.ccv, ti.erv_percent, ti.trust_index_score,
                 ti.engine_version, ti.erv, ti.authenticity, ti.band_row, ti.band_color,
                 CASE WHEN ti.engine_version = 'v2' THEN ti.erv
                      WHEN ti.ccv > 0 AND ti.erv_percent IS NOT NULL
                      THEN ROUND(ti.ccv * ti.erv_percent / 100.0)
                      ELSE NULL END AS real_viewers
          FROM streams s
          JOIN channels c ON c.id = s.channel_id AND c.deleted_at IS NULL AND c.is_monitored = TRUE
          LEFT JOIN LATERAL (
            SELECT tih.ccv, tih.erv_percent, tih.trust_index_score,
                   tih.engine_version, tih.erv, tih.authenticity, tih.band_row, tih.band_color
            FROM trust_index_histories tih
            WHERE tih.channel_id = s.channel_id
              AND ((tih.engine_version = 'v1' AND tih.erv_percent IS NOT NULL)
                OR (tih.engine_version = 'v2' AND tih.erv IS NOT NULL))
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
      @user.tracked_channels.where(tracking_enabled: true).pluck(:channel_id).to_set
    end

    def build(row, watched)
      v2 = row["engine_version"] == "v2"
      pct = (v2 ? row["authenticity"] : row["erv_percent"])&.to_f
      label, color = label_and_color(row, v2, pct)
      ti = (v2 ? row["authenticity"] : row["trust_index_score"])&.to_f
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
        ti_score: ti&.round(1)
      }
    end

    # v2 rows carry no erv_label text — re-derive it from the persisted band_row via the canonical
    # BandClassifier map + band.<key>.ru locale (mirrors the card headline). v1 legacy rows keep the
    # ErvCalculator label. Returns [label_ru, color].
    def label_and_color(row, v2, pct)
      if v2
        key = TrustIndex::V2::BandClassifier::LABEL_KEYS_BY_ROW[row["band_row"].to_i]
        label = key ? I18n.t(key, locale: :ru, default: nil) : nil
        [ label, row["band_color"] ]
      else
        label = pct ? TrustIndex::ErvCalculator.resolve_label(pct) : nil
        [ label && label[:ru], label && label[:color] ]
      end
    end
  end
end
