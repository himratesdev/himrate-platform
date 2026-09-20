# frozen_string_literal: true

module Calibration
  # Read-only loader for Calibration::Reseed: turns persisted TI v2 verdicts (trust_index_histories)
  # into per-(stream, cell) observations + the last-hour fleet at the same grain + the current cells.
  #
  # Why persisted rows and not docker logs (what ti-v2-shadow-mine.yml mined): every v2 verdict
  # already persists the engine's OWN ρ_obs with its convention stamp (rho_convention='windowed' =
  # EIHC_W / min(V_W, V_inst), exactly the frame L2 divides by), eihc (so V_eff = eihc/ρ_obs recovers
  # the V the engine bucketed the cell on), cold_start_tier, band, the corroborator flags and q_score
  # (= 1 − temporally-flagged non-utility share of the roster, the miner's spam gate). Logs rotated in
  # ~30 min and had to be pooled across dozens of runs; the table holds every verdict of the window.
  #
  # Load discipline (the box is shared and often saturated):
  #   * one READ ONLY transaction with a statement_timeout; nothing is written anywhere;
  #   * ONE contiguous window, driven off the ~700 partner channels, so the planner reads it as a
  #     range on the calculated_at index. Sub-sampling the window into disjoint slices (the first
  #     shape this took) makes the planner give up on the index and sequentially scan all 7.9M rows
  #     instead — measured, not guessed. So the WINDOW is what gets fitted to the IO budget, not the
  #     sampling density; and the plan is EXPLAIN-checked first: a sequential scan of
  #     trust_index_histories aborts before the query runs.
  class ReseedCorpus
    Result = Data.define(:observations, :current, :fleet, :fleet_hours, :meta)

    TABLE = "trust_index_histories"
    ANCHOR_BROADCASTER_TYPE = "partner"
    ANOMALY_TYPES = %w[viewbot_spike ccv_step_function].freeze
    # Accusatory band rows (1 RED, 2 YELLOW) + every persisted corroborator flag. c_inflation /
    # c_hard_abs / c_pop exist only after 20260919120000 — read where the table has them (band_row
    # already covers any accusation they drove).
    ACCUSATORY_MAX_ROW = 2
    ALWAYS_FLAGS = %w[confirmed_anomaly c_hard c_self].freeze
    OPTIONAL_FLAGS = %w[c_inflation c_hard_abs c_pop].freeze
    # Never shrink the window below this — under a day the thin cells (5k-20k, 20k+, sub-only) lose
    # every channel they have and the run reports "no data" where it should report a baseline.
    MIN_WINDOW_HOURS = 24

    # plan_guard: false only for specs — a near-empty test table always plans as a seq scan.
    # io_budget_mb 900 ≈ 3 days at the current ~27k verdicts/h × ~440 B/row — enough for the thin
    # cells to collect channels, small enough that the index range stays inside the page cache.
    def initialize(since: nil, until_at: nil, window_days: 7, io_budget_mb: 900, min_v: 50,
                   fleet_minutes: 60, statement_timeout_s: 300, plan_guard: true)
      @until = (until_at || Time.current).utc
      @since = (since || (@until - window_days.to_f.days)).utc
      raise ArgumentError, "since must be before until" unless @since < @until

      @budget_bytes = io_budget_mb.to_f * 1024 * 1024
      @min_v = min_v.to_f
      @fleet_minutes = fleet_minutes.to_i
      @timeout_s = statement_timeout_s.to_i
      @plan_guard = plan_guard
    end

    def load
      result = nil
      read_only do
        k = Calibration::Registry.load
        floor = [ k.deficit_min_ccv.to_f, 0.0 ].max
        current = CalibrationCellBaseline.all.to_a
        fleet_raw, fleet_meta = fleet_rows(floor)
        stats = table_stats
        rows_per_hour = fleet_meta[:rows] * 60.0 / @fleet_minutes
        since = fit_since(stats[:bytes_per_row], rows_per_hour)
        observations, obs_meta = build_observations(corpus_rows(since))
        fleet = build_fleet(fleet_raw)
        result = Result.new(
          observations: observations, current: current, fleet: fleet, fleet_hours: @fleet_minutes / 60.0,
          meta: {
            window: "#{since.iso8601} .. #{@until.iso8601} (#{format('%.1f', (@until - since) / 86_400.0)}d)",
            sampling: since > @since ? "window shortened from #{format('%.1f', (@until - @since) / 86_400.0)}d to fit the IO budget" : "full requested window, partner channels only",
            est_heap_read: format("%.0f MB of %.0f MB budget — a FLOOR: main fork only, the index pages the " \
                                  "scan walks and any TOAST are NOT counted (total relation is %.1f× the heap)",
                                  est_bytes(since, stats[:bytes_per_row], rows_per_hour) / 1_048_576.0,
                                  @budget_bytes / 1_048_576.0, stats[:total_ratio]),
            table: format("%.1fM rows, %.0f B/row heap", stats[:reltuples] / 1e6, stats[:bytes_per_row]),
            fleet: "#{fleet_meta[:rows]} verdicts in last #{@fleet_minutes} min (#{fleet_meta[:cumulative]} cumulative-convention)",
            corpus: obs_meta,
            min_v: @min_v, deficit_min_ccv_live: floor,
            # A non-zero parent count REFUSES the plan (Reseed#refuse_parent_cells!) — this planner
            # does not walk the chain CellResolver walks, so it would diff against the wrong baseline.
            current_cells: "#{current.size} rows (#{current.count(&:calibrated)} calibrated, #{current.count(&:parent_cell_id)} with parent — any is a refusal), " \
                           "last update #{current.map(&:updated_at).compact.max&.utc&.iso8601}"
          }
        )
      end
      result
    end

    # SQL V-bucket, generated from TrustIndex::V2::CellKey so the two can never drift.
    def self.v_bucket_sql(v)
      whens = TrustIndex::V2::CellKey::V_BUCKETS.map { |ceil, label| "WHEN #{v} < #{Integer(ceil)} THEN '#{label}'" }.join(" ")
      "CASE WHEN #{v} IS NULL OR #{v} <= 0 THEN '0' #{whens} ELSE '20k+' END"
    end

    # The V the engine bucketed the cell on and divided the deficit by: ρ_obs = EIHC / V_eff with
    # V_eff = min(V_W, V_inst) (L2Presume), so V_eff = EIHC / ρ_obs; rounded because both inputs are
    # integer counts. ρ_obs = 0 (no chatters) leaves only the instant V.
    V_EFF_SQL = "CASE WHEN t.rho_obs > 0 AND t.eihc > 0 THEN round(t.eihc / t.rho_obs) ELSE t.ccv END"

    private

    def conn = ActiveRecord::Base.connection

    def read_only
      top_level = conn.open_transactions.zero?
      ActiveRecord::Base.transaction(requires_new: true) do
        conn.execute("SET TRANSACTION READ ONLY") if top_level # outer test transactions: skip (can't re-mode)
        conn.execute("SET LOCAL statement_timeout = '#{@timeout_s}s'")
        yield
        raise ActiveRecord::Rollback
      end
    end

    # pg_relation_size is the MAIN FORK ONLY — no indexes, no TOAST. That is the right per-row unit
    # (what the range scan pays is a heap fetch per matched row), but it makes the estimate a FLOOR
    # rather than a full IO account: the index pages the scan walks to get there are not in it. The
    # total/heap ratio comes back with it so the printed number can say how much is left uncounted.
    def table_stats
      row = conn.select_one(<<~SQL)
        SELECT c.reltuples::float8 AS reltuples, pg_relation_size(c.oid)::float8 AS heap_bytes,
               pg_total_relation_size(c.oid)::float8 AS total_bytes
        FROM pg_class c WHERE c.relname = '#{TABLE}' AND c.relkind IN ('r', 'p')
      SQL
      tuples = [ row["reltuples"].to_f, 1.0 ].max
      heap = row["heap_bytes"].to_f
      { reltuples: tuples, bytes_per_row: heap / tuples,
        total_ratio: heap.positive? ? row["total_bytes"].to_f / heap : 1.0 }
    end

    def est_bytes(since, bytes_per_row, rows_per_hour)
      rows_per_hour * ((@until - since) / 3600.0) * bytes_per_row
    end

    # The window, not the sampling density, is what fits the IO budget: the scan has to stay ONE
    # contiguous range or the planner stops using the calculated_at index (see the class note), so
    # there is nothing to thin out — only a nearer @since to move to. bytes_per_row is heap-only
    # (table_stats), so the window this returns is the most generous one the budget allows, not a
    # cautious one — leave headroom when the box is already loaded.
    def fit_since(bytes_per_row, rows_per_hour)
      per_hour = [ rows_per_hour * bytes_per_row, 1.0 ].max
      affordable = @budget_bytes / per_hour
      requested = (@until - @since) / 3600.0
      return @since if requested <= affordable

      @until - [ affordable, MIN_WINDOW_HOURS.to_f ].max.hours
    end

    def accused_sql
      flags = ALWAYS_FLAGS + (OPTIONAL_FLAGS & TrustIndexHistory.column_names)
      ([ "COALESCE(t.band_row, 9) <= #{ACCUSATORY_MAX_ROW}" ] + flags.map { |f| "COALESCE(t.#{f}, false)" }).join(" OR ")
    end

    def ts(t) = conn.quote(t.utc)

    # Last-hour fleet, one range on the calculated_at index. rhos = every non-null ρ_obs whose
    # V_eff clears the live deficit floor (the verdicts ρ* actually judges), both conventions.
    def fleet_rows(floor)
      since = @until - @fleet_minutes.minutes
      sql = <<~SQL
        SELECT t.stream_id, t.channel_id, #{self.class.v_bucket_sql(V_EFF_SQL)} AS vb,
               count(*) AS verdicts,
               count(*) FILTER (WHERE t.rho_convention = 'cumulative') AS cumulative,
               bool_and(COALESCE(t.cold_start_tier, '') = 'full') AS full_tier,
               array_agg(t.rho_obs::float8) FILTER (WHERE t.rho_obs IS NOT NULL AND (#{V_EFF_SQL}) >= #{floor}) AS rhos
        FROM #{TABLE} t
        WHERE t.engine_version = 'v2' AND t.calculated_at >= #{ts(since)} AND t.calculated_at < #{ts(@until)}
        GROUP BY 1, 2, 3
      SQL
      guard_plan!(sql)
      rows = typed(conn.select_all(sql))
      [ rows, { rows: rows.sum { |r| r["verdicts"].to_i }, cumulative: rows.sum { |r| r["cumulative"].to_i } } ]
    end

    # The honest-candidate corpus over one contiguous window, DRIVEN FROM the ~700 partner channels
    # (of ~3.5k) so the planner joins them against a calculated_at index range. Non-partner verdicts
    # were never corpus material — the honest anchor has to be a partner — so scanning them only to
    # count them costs a full table scan; the last-hour fleet query carries the fleet-wide picture
    # instead. Rejection counts are therefore partner-scoped: "of the anchors we could have used,
    # this many were disqualified, for these reasons".
    def corpus_rows(since)
      usable = "t.rho_convention = 'windowed' AND t.rho_obs IS NOT NULL AND (#{V_EFF_SQL}) >= #{@min_v}"
      sql = <<~SQL
        SELECT t.stream_id, t.channel_id, #{self.class.v_bucket_sql(V_EFF_SQL)} AS vb,
               true AS partner,
               count(*) AS n_rows,
               bool_or(#{accused_sql}) AS accused,
               bool_and(COALESCE(t.cold_start_tier, '') = 'full') AS full_tier,
               (array_agg(t.q_score::float8 ORDER BY t.calculated_at DESC))[1] AS q_last,
               max(t.calculated_at) AS last_at,
               array_agg(t.rho_obs::float8) FILTER (WHERE #{usable}) AS rhos,
               percentile_disc(0.5) WITHIN GROUP (ORDER BY t.rho_obs::float8)
                 FILTER (WHERE #{usable} AND t.band_color = 'green') AS green_median
        FROM channels c
        JOIN #{TABLE} t ON t.channel_id = c.id
          AND t.calculated_at >= #{ts(since)} AND t.calculated_at < #{ts(@until)}
        WHERE c.broadcaster_type = #{conn.quote(ANCHOR_BROADCASTER_TYPE)} AND t.engine_version = 'v2'
        GROUP BY 1, 2, 3
      SQL
      guard_plan!(sql)
      typed(conn.select_all(sql))
    end

    # EXPLAIN (no ANALYZE — nothing executes) and refuse a sequential scan of the big table.
    def guard_plan!(sql)
      return unless @plan_guard

      plan = conn.select_values("EXPLAIN #{sql}").join("\n")
      return unless plan.match?(/Seq Scan on #{TABLE}\b/)

      raise "refusing to run: planner chose a sequential scan of #{TABLE}\n#{plan}"
    end

    # Rows as Hashes with PG types applied (float8[] → Array<Float>, bool, Time). Every query here
    # selects several columns, so cast_values always yields one Array per row.
    def typed(result)
      result.cast_values.map { |vals| result.columns.zip(vals).to_h }
    end

    def build_observations(rows)
      by_stream = rows.group_by { |r| r["stream_id"] }
      streams = stream_meta(by_stream.keys)
      configs = protection_configs(rows.map { |r| r["channel_id"] }.uniq)
      partner_streams = by_stream.select { |_, rs| rs.any? { |r| r["partner"] } }.keys
      anomalous = anomalous_streams(partner_streams)

      obs = []
      by_stream.each do |sid, rs|
        s = streams[sid] or next
        latest = rs.max_by { |r| r["last_at"] }
        facts = { partner: rs.any? { |r| r["partner"] }, full_tier: rs.all? { |r| r["full_tier"] },
                  accused: rs.any? { |r| r["accused"] }, anomaly: anomalous.include?(sid), q: latest["q_last"]&.to_f }
        rs.each do |r|
          obs << Reseed::Observation.new(
            stream_id: sid, channel_id: r["channel_id"], cell: cell(s, r["vb"], configs[r["channel_id"]]),
            rhos: Array(r["rhos"]).compact.map(&:to_f), green_median: r["green_median"]&.to_f, **facts
          )
        end
      end
      meta = "#{rows.sum { |r| r['n_rows'].to_i }} sampled v2 verdicts, #{by_stream.size} streams " \
             "(#{partner_streams.size} partner), #{obs.sum { |o| o.rhos.size }} usable partner windowed ρ_obs"
      [ obs, meta ]
    end

    def build_fleet(rows)
      streams = stream_meta(rows.map { |r| r["stream_id"] }.uniq)
      configs = protection_configs(rows.map { |r| r["channel_id"] }.uniq)
      rows.filter_map do |r|
        s = streams[r["stream_id"]] or next
        Reseed::FleetObservation.new(cell: cell(s, r["vb"], configs[r["channel_id"]]), verdicts: r["verdicts"].to_i,
                                     rhos: Array(r["rhos"]).compact.map(&:to_f), full_tier: r["full_tier"] == true)
      end
    end

    StreamMeta = Struct.new(:game_name, :language)

    def stream_meta(ids)
      ids.each_slice(5_000).each_with_object({}) do |chunk, h|
        Stream.where(id: chunk).pluck(:id, :game_name, :language).each { |id, g, l| h[id] = StreamMeta.new(g, l) }
      end
    end

    def protection_configs(channel_ids)
      channel_ids.each_slice(5_000).each_with_object({}) do |chunk, h|
        ChannelProtectionConfig.where(channel_id: chunk).each { |c| h[c.channel_id] = c }
      end
    end

    # Canon: a viewbot_spike / ccv_step_function on the stream disqualifies it unless the stream was raided.
    def anomalous_streams(stream_ids)
      return Set.new if stream_ids.empty?

      hit = stream_ids.each_slice(5_000).flat_map do |chunk|
        Anomaly.where(stream_id: chunk, anomaly_type: ANOMALY_TYPES).where(timestamp: @since..@until).distinct.pluck(:stream_id)
      end
      raided = hit.each_slice(5_000).flat_map { |chunk| RaidAttribution.where(stream_id: chunk).distinct.pluck(:stream_id) }
      (hit - raided).to_set
    end

    # The engine's own key (TrustIndex::V2::CellKey) — category from the stream's game, V-bucket as the
    # engine bucketed it (SQL above), chat mode from the channel's protection settings, language verbatim.
    def cell(stream, v_bucket, config)
      Reseed::Cell.new(category: TrustIndex::V2::CellKey.category_for(stream), v_bucket: v_bucket,
                       chat_mode: TrustIndex::V2::CellKey.chat_mode(config),
                       language: TrustIndex::V2::CellKey.language_for(stream))
    end
  end
end
