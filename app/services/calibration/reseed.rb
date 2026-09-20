# frozen_string_literal: true

require "json"
require "fileutils"

module Calibration
  # Per-cell honest-baseline ρ* re-seed for the TI v2 L2 deficit (calibration_cell_baselines).
  # Server-side, in-repo replacement for the GitHub-Actions pair ti-v2-shadow-mine.yml (hourly
  # docker-log harvest) + ti-v2-rho-reseed.yml (dryrun/apply), retired with the account on
  # 2026-09-01 and not coming back.
  #
  # PURE COMPUTATION: .plan takes per-(stream, cell) observations of the engine's OWN persisted
  # windowed ρ_obs (Calibration::ReseedCorpus reads them off trust_index_histories, read-only) plus
  # the current cells, and returns the proposed cells with the diff. The only writers are .apply!
  # and .restore!, reachable from the rake task solely in mode=apply with CONFIRM_RESEED=yes.
  #
  # Method — canon _tasks/T1-074/GATE0-WINDOWED-RESEED-PROPOSAL-2026-07-25 + rho-raw/aggregate_windowed.rb:
  #   1. Honest filter on evidence that does NOT depend on ρ*: partner ∧ full cold-start tier ∧ no
  #      accusatory verdict anywhere in the stream ∧ no un-raided viewbot/ccv-step anomaly ∧ roster
  #      spam ≤ 5% (q ≥ 0.95). Deliberately NOT authenticity ≥ 88 / GREEN: with nothing named,
  #      A ≥ 88 ⟺ ρ_obs ≥ 0.88·ρ*_live, so that filter keeps only channels that already agree with the
  #      baseline being replaced — a stale-high cell could never come down. The GREEN-only median is
  #      still computed (green_only_star) so the size of that circularity is visible per cell.
  #   2. (stream, cell) median of verdict-level ρ_obs — the engine's runtime distribution;
  #   3. (channel, cell) median of that channel's stream medians — ONE vote per channel, so a
  #      channel that streams all week cannot outvote one that streamed once;
  #   4. votes above OUTLIER_RHO dropped before quantiles (tiny-V artefacts, canon 2.0);
  #   5. ρ_lo = P10, ρ* = P50, ρ_hi = P90, nearest rank; only cells with ≥ min_channels votes.
  # rho_p1 / ccv_typical (C_pop) are NOT written: C_pop needs n ≥ 150 per cell and is dormant;
  # apply leaves both columns exactly as they are.
  class Reseed
    Cell = Data.define(:category, :v_bucket, :chat_mode, :language) do
      def key = [ category, v_bucket, chat_mode, language ].join("|")
    end

    # One stream's verdicts inside one cell (a stream crossing a V-bucket boundary yields one per
    # bucket). rhos = its verdict-level windowed ρ_obs above the V floor; green_median = the median of
    # only its GREEN verdicts (nil if none). The facts are STREAM-level — the corpus ORs/ANDs them
    # across the stream's buckets — so a stream accused in one bucket is out of all of them.
    Observation = Data.define(:stream_id, :channel_id, :cell, :rhos, :green_median,
                              :partner, :full_tier, :accused, :anomaly, :q)

    # The live fleet at the same grain over the last fleet window: verdicts = every v2 verdict (the
    # traffic this cell decides); rhos = those carrying a ρ_obs at or above the live deficit floor
    # (the ones ρ* actually judges).
    FleetObservation = Data.define(:cell, :verdicts, :rhos, :full_tier)

    # What a cell resolves to — `source` says how: the exact row, the "default"-category row, or the
    # engine's built-in DEFAULT (uncalibrated, can never accuse).
    Baseline = Data.define(:rho_star, :rho_lo, :rho_hi, :sample_size, :calibrated, :source)

    Proposal = Data.define(:rho_star, :rho_lo, :rho_hi, :sample_size)

    FleetEffect = Data.define(:verdicts_per_hour, :judged, :amber_now, :amber_new, :yellow_zone_now, :yellow_zone_new)

    CellPlan = Data.define(:cell, :status, :n_channels, :honest_verdicts, :now, :proposed,
                           :green_only_star, :honest_below_lo_now, :honest_below_lo_new,
                           :honest_yellow_zone_now, :honest_yellow_zone_new, :fleet, :notes) do
      # :new / :update are written by apply; everything else is report-only.
      def apply? = %i[new update].include?(status)
    end

    Plan = Data.define(:cells, :rejected, :honest_streams, :dropped_outliers, :params)

    Refused = Class.new(StandardError)

    DEFAULTS = {
      min_channels: 8,     # canon MIN_N (miner + aggregator): below it a cell is not re-seeded
      mature_channels: 12, # canon maturity bar: 8..11 are applied but flagged thin
      min_rows: 3,         # verdicts a (stream, cell) needs before its median counts
      outlier_rho: 2.0,    # canon OUTLIER guard — dropped before quantiles
      q_min: 0.95,         # canon spam gate: ≤ 5% temporally-flagged non-utility chatters
      p_lo: 0.10, p_star: 0.50, p_hi: 0.90,
      # Offline honest-safety gate — replaces the old workflow's live honest re-scan (which re-ran the
      # engine per stream against ClickHouse). Share of honest verdicts the new ρ_lo would place in the
      # YELLOW-eligible deficit zone (band row2: F_soft_lo/V ≥ 0.20 ⟺ ρ_obs < 0.8·ρ_lo). Honest
      # channels carry no corroborator, so this is exposure, not an accusation. This is the ABSOLUTE
      # arm of the gate; see honest_safe? for why it is not the only arm.
      max_honest_yellow_zone: 0.10,
      fleet_hours: 1.0
    }.freeze

    # BandClassifier row2: f_soft_lo_ratio ≥ 0.20 → F_soft_lo/V = 1 − ρ_obs/ρ_lo ≥ 0.20.
    YELLOW_ZONE = 0.80
    # BandClassifier row4 (green) needs â ≤ 0.20; with nothing named F̂ ≈ F_soft → ρ_obs ≥ 0.8·ρ*.
    GREEN_FLOOR = 0.80
    # Below this many votes a cell gets no quantiles at all, not even indicative ones.
    INDICATIVE_MIN = 3

    APPLY_CONFIRM_ENV = "CONFIRM_RESEED"
    RESTORABLE = %w[rho_star rho_lo rho_hi sample_size calibrated rho_p1 ccv_typical parent_cell_id].freeze

    # ---------------------------------------------------------------------------------------------
    # Entry point used by the rake task. dryrun computes and renders; apply refuses BEFORE the corpus
    # is even loaded unless confirm == "yes", then writes the applicable cells in one transaction.
    # corpus_loader: -> { Calibration::ReseedCorpus::Result } (lazy, so a refused apply costs nothing).
    def self.run(mode:, corpus_loader:, confirm: nil, snapshot_dir: nil, io: $stdout, **opts)
      mode = mode.to_s
      raise ArgumentError, "mode must be dryrun or apply (got #{mode.inspect})" unless %w[dryrun apply].include?(mode)
      if mode == "apply" && confirm != "yes"
        raise Refused, "apply refused: set #{APPLY_CONFIRM_ENV}=yes — a re-seed changes accusations fleet-wide"
      end

      corpus = corpus_loader.call
      plan = plan(observations: corpus.observations, current: corpus.current, fleet: corpus.fleet,
                  fleet_hours: corpus.fleet_hours, **opts)
      io.puts render(plan, meta: corpus.meta)
      return { plan: plan, snapshot: nil } if mode == "dryrun"

      path = apply!(plan, snapshot_dir: snapshot_dir || default_snapshot_dir)
      io.puts "\nAPPLIED #{plan.cells.count(&:apply?)} cell(s). Restore: bin/rails 'calibration:reseed_restore[#{path}]'"
      io.puts "  ⚠ this snapshot holds the cells as they stood BEFORE THIS apply. A SECOND apply snapshots what"
      io.puts "    THIS one wrote — only the EARLIEST file restores the pre-re-seed cells, and several applies"
      io.puts "    must be undone newest-first. Keep every snapshot; they are the only history there is."
      { plan: plan, snapshot: path }
    end

    def self.plan(observations:, current:, fleet: [], **opts)
      new(**opts).plan(observations: observations, current: current, fleet: fleet)
    end

    def initialize(**opts)
      unknown = opts.keys - DEFAULTS.keys
      raise ArgumentError, "unknown reseed option(s): #{unknown.join(', ')}" if unknown.any?

      @p = DEFAULTS.merge(opts)
      # RESEED_MIN_CHANNELS is an operator knob, so it can be set below the floor under which no
      # quantiles are computed at all — a cell would then clear the n-gate with nothing to write
      # (status_for reads proposed.rho_lo). Refused rather than clamped: a run asked for a bar it
      # cannot have should say so, not silently re-seed on a different one.
      if @p[:min_channels] < INDICATIVE_MIN
        raise ArgumentError, "min_channels=#{@p[:min_channels]} is below INDICATIVE_MIN=#{INDICATIVE_MIN}: " \
                             "a cell with fewer than #{INDICATIVE_MIN} votes gets no quantiles at all, so it " \
                             "could pass the n-gate with nothing to propose (canon MIN_N=#{DEFAULTS[:min_channels]})"
      end
    end

    def plan(observations:, current:, fleet: [])
      refuse_parent_cells!(current)
      @current = index_current(current)
      rejected = Hash.new(0)
      honest = []
      observations.group_by(&:stream_id).each_value do |obs|
        reason = rejection(obs.first)
        reason ? rejected[reason] += 1 : honest.concat(obs)
      end

      acc = accumulate(honest)
      fleet_by_cell = fleet.group_by { |f| f.cell.key }
      dropped = {}
      keys = (acc[:cells].keys + @current.keys + fleet_by_cell.keys).uniq
      cells = keys.map do |key|
        cell = acc[:cells][key] || @current[key]&.then { |c| cell_of(c) } || fleet_by_cell[key].first.cell
        cell_plan(cell, acc, fleet_by_cell[key] || [], dropped)
      end

      Plan.new(cells: cells.sort_by { |c| [ status_rank(c.status), -c.fleet.verdicts_per_hour, c.cell.key ] },
               rejected: rejected.to_h, honest_streams: honest.map(&:stream_id).uniq.size,
               dropped_outliers: dropped, params: @p)
    end

    # ---------------------------------------------------------------------------------------------
    # Writers (apply only). One transaction, and the snapshot of the rows about to change is on disk
    # BEFORE the first row is written — but under a `.partial` name, renamed into place only once the
    # transaction has committed. The invariant has two halves and a plain write inside the transaction
    # only holds one of them: a file written inside SURVIVES a rollback, so a failed apply left a
    # snapshot of writes that never happened — an operator restoring from it would "undo" values that
    # are still live. Writing after the commit instead would lose the other half (a committed apply
    # with no snapshot if the process dies in between). Write-then-rename keeps both: the data is
    # durable before the first write, and only a commit publishes it under the restorable name.
    #
    # A cell that did not exist is recorded with previous: nil so restore deletes it rather than
    # leaving an uncalibrated row the resolver would still hand to the engine.
    #
    # ⚠ SNAPSHOT SEMANTICS: the file holds the cells as they stood BEFORE THIS apply. Apply twice and
    # the second snapshot captures what the FIRST one wrote — only the EARLIEST file restores the
    # pre-re-seed cells, and a stack of applies has to be undone newest-first.
    def self.apply!(plan, snapshot_dir:)
      rows = plan.cells.select(&:apply?)
      raise Refused, "nothing to apply — no cell passed min_channels and the honest-safety gate" if rows.empty?

      path = snapshot_path(snapshot_dir)
      partial = "#{path}.partial"
      committed = false
      begin
        CalibrationCellBaseline.transaction do
          snapshot = rows.map do |cp|
            rec = CalibrationCellBaseline.lock.find_by(**cp.cell.to_h)
            { "cell" => cp.cell.to_h.transform_keys(&:to_s),
              "previous" => rec&.attributes&.slice(*RESTORABLE)&.transform_values { |v| v.is_a?(BigDecimal) ? v.to_s : v },
              "applied" => cp.proposed.to_h.transform_keys(&:to_s) }
          end
          write_snapshot!(snapshot, partial)
          rows.each do |cp|
            b = CalibrationCellBaseline.find_or_initialize_by(**cp.cell.to_h)
            b.assign_attributes(rho_star: cp.proposed.rho_star, rho_lo: cp.proposed.rho_lo,
                                rho_hi: cp.proposed.rho_hi, sample_size: cp.proposed.sample_size, calibrated: true)
            b.save!
          end
        end
        committed = true
      ensure
        FileUtils.rm_f(partial) unless committed
      end

      begin
        File.rename(partial, path)
      rescue SystemCallError => e
        raise Refused, "the cells ARE written and committed, but the snapshot could not be renamed to " \
                       "#{path} — restore from #{partial} instead (#{e.message})"
      end
      path
    end

    # Puts every cell named in an apply snapshot back exactly as it was (deleting the ones apply
    # created). Restoring a stack of applies means newest-first: each file only knows the state the
    # apply that wrote it replaced.
    def self.restore!(snapshot_path)
      doc = JSON.parse(File.read(snapshot_path))
      CalibrationCellBaseline.transaction do
        doc.fetch("cells").each do |entry|
          key = entry.fetch("cell").transform_keys(&:to_sym)
          prev = entry["previous"]
          if prev.nil?
            CalibrationCellBaseline.where(**key).delete_all
          else
            b = CalibrationCellBaseline.find_or_initialize_by(**key)
            b.assign_attributes(prev)
            b.save!
          end
        end
      end
      doc.fetch("cells").size
    end

    def self.write_snapshot!(cells, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate({ "written_at" => Time.now.utc.iso8601, "cells" => cells }))
      path
    end

    # Second-resolution name, suffixed if taken: two applies inside the same second must not share a
    # file, because the older of the two is the only one that restores the pre-re-seed cells.
    def self.snapshot_path(dir)
      base = File.join(dir, "reseed-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
      path = "#{base}.json"
      n = 1
      while File.exist?(path) || File.exist?("#{path}.partial")
        n += 1
        path = "#{base}-#{n}.json"
      end
      path
    end

    # storage/ is the persistent docker volume (himrate_storage) — survives redeploys.
    def self.default_snapshot_dir
      Rails.root.join("storage", "calibration").to_s
    end

    # ---------------------------------------------------------------------------------------------
    # Rendering: a fixed-width table for the terminal + one JSON line for machines.
    def self.render(plan, meta: {})
      lines = []
      lines << "== ρ* RE-SEED PLAN (dry computation — nothing written) =="
      meta.each { |k, v| lines << format("  %-22s %s", k, v) }
      lines << format("  %-22s %d honest streams; rejected %s", "honest filter", plan.honest_streams,
                      plan.rejected.sort_by { |_, v| -v }.map { |k, v| "#{k}=#{v}" }.join(" "))
      lines << format("  %-22s %s", "outliers dropped", plan.dropped_outliers.empty? ? "none" : plan.dropped_outliers)
      lines << ""
      lines << format("%-48s %-10s %4s %7s  %-15s %-15s %-15s %-13s %-13s %7s  %-13s %-13s",
                      "cell", "status", "n", "hon.v", "rho* now>new", "rho_lo now>new", "rho_hi now>new",
                      "hon<lo now>new", "hon.yz now>new", "fleet/h", "amber now>new", "yzone now>new")
      plan.cells.each do |c|
        next if c.status == :no_data && c.fleet.verdicts_per_hour < 1

        lines << format("%-48s %-10s %4d %7d  %-15s %-15s %-15s %-13s %-13s %7.0f  %-13s %-13s",
                        c.cell.key, c.status, c.n_channels, c.honest_verdicts,
                        arrow(c.now.rho_star, c.proposed&.rho_star, c.now), arrow(c.now.rho_lo, c.proposed&.rho_lo, c.now),
                        arrow(c.now.rho_hi, c.proposed&.rho_hi, c.now),
                        pct_arrow(c.honest_below_lo_now, c.honest_below_lo_new),
                        pct_arrow(c.honest_yellow_zone_now, c.honest_yellow_zone_new),
                        c.fleet.verdicts_per_hour,
                        pct_arrow(c.fleet.amber_now, c.fleet.amber_new), pct_arrow(c.fleet.yellow_zone_now, c.fleet.yellow_zone_new))
        c.notes.each { |n| lines << "    · #{n}" }
      end
      lines << ""
      lines << "JSON #{JSON.generate(serialize(plan, meta))}"
      lines.join("\n")
    end

    def self.arrow(now, new, baseline)
      tag = baseline.source == :engine_default ? "D" : (baseline.calibrated ? "" : "u")
      left = now.nil? ? "—" : format("%.3f%s", now, tag)
      new.nil? ? left : "#{left}>#{format('%.3f', new)}"
    end

    def self.pct_arrow(now, new)
      l = now.nil? ? "—" : format("%.0f%%", now * 100)
      new.nil? ? l : "#{l}>#{format('%.0f%%', new * 100)}"
    end

    def self.serialize(plan, meta)
      { meta: meta, params: plan.params, rejected: plan.rejected, honest_streams: plan.honest_streams,
        dropped_outliers: plan.dropped_outliers,
        cells: plan.cells.map do |c|
          c.to_h.merge(cell: c.cell.to_h, now: c.now.to_h, proposed: c.proposed&.to_h, fleet: c.fleet.to_h)
        end }
    end

    private

    def rejection(o)
      return :not_partner unless o.partner
      return :not_full_tier unless o.full_tier
      return :accused if o.accused
      return :anomaly if o.anomaly
      return :spam_roster if o.q && o.q < @p[:q_min]

      nil
    end

    # votes[key][channel] = [stream medians]; greens likewise over GREEN-only medians;
    # verdicts[key] = the honest verdict-level ρ_obs (for the shares).
    def accumulate(honest)
      acc = { cells: {}, votes: Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } },
              greens: Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } },
              verdicts: Hash.new { |h, k| h[k] = [] } }
      honest.each do |o|
        next if o.rhos.size < @p[:min_rows]

        key = o.cell.key
        acc[:cells][key] = o.cell
        acc[:votes][key][o.channel_id] << median(o.rhos)
        acc[:greens][key][o.channel_id] << o.green_median if o.green_median
        acc[:verdicts][key].concat(o.rhos)
      end
      acc
    end

    def cell_plan(cell, acc, fleet_obs, dropped)
      key = cell.key
      raw = acc[:votes].key?(key) ? acc[:votes][key].values.map { |ms| median(ms) } : []
      kept = raw.reject { |v| v > @p[:outlier_rho] }
      dropped[key] = raw.size - kept.size if raw.size > kept.size
      now = resolve_now(cell)
      proposed = kept.size >= INDICATIVE_MIN ? quantiles(kept) : nil
      verdicts = acc[:verdicts].key?(key) ? acc[:verdicts][key] : []
      status, notes = status_for(key, kept.size, proposed, verdicts, now)
      applied = %i[new update].include?(status) ? proposed : nil

      greens = acc[:greens].key?(key) ? acc[:greens][key].values.map { |ms| median(ms) }.reject { |v| v > @p[:outlier_rho] } : []
      CellPlan.new(
        cell: cell, status: status, n_channels: kept.size, honest_verdicts: verdicts.size, now: now,
        proposed: proposed,
        green_only_star: greens.size >= INDICATIVE_MIN ? nearest_rank(greens.sort, @p[:p_star]) : nil,
        honest_below_lo_now: share(verdicts) { |r| r < now.rho_lo },
        honest_below_lo_new: proposed && share(verdicts) { |r| r < proposed.rho_lo },
        honest_yellow_zone_now: yellow_zone_now(verdicts, now),
        honest_yellow_zone_new: proposed && share(verdicts) { |r| r < YELLOW_ZONE * proposed.rho_lo },
        fleet: fleet_effect(fleet_obs, now, applied), notes: notes
      )
    end

    def status_for(key, n, proposed, verdicts, now)
      notes = []
      exists = @current.key?(key)
      if n < @p[:min_channels]
        notes << "n=#{n} < #{@p[:min_channels]} — not re-seeded#{exists ? ', current row kept as is' : ''}" if n.positive? || exists
        return [ exists ? :held_thin : (n.positive? ? :thin : :no_data), notes ]
      end

      # n ≥ min_channels ≥ INDICATIVE_MIN (enforced in the constructor) ⟹ proposed is never nil here.
      unless proposed.rho_lo.positive? && proposed.rho_lo <= proposed.rho_star && proposed.rho_star <= proposed.rho_hi
        return [ :unsafe, notes << "invalid interval lo=#{proposed.rho_lo} star=#{proposed.rho_star} hi=#{proposed.rho_hi}" ]
      end

      yz_new = share(verdicts) { |r| r < YELLOW_ZONE * proposed.rho_lo }
      yz_now = yellow_zone_now(verdicts, now)
      unless honest_safe?(yz_now, yz_new)
        return [ :unsafe, notes << format("honest YELLOW-zone share %.1f%%→%.1f%%: widens exposure and clears the %.0f%% gate — not applied",
                                          (yz_now || 0) * 100, yz_new * 100, @p[:max_honest_yellow_zone] * 100) ]
      end

      notes << format("honest YELLOW-zone exposure %.1f%%→%.1f%% (above the %.0f%% bar, but NARROWER than today's ρ_lo)",
                      (yz_now || 0) * 100, yz_new * 100, @p[:max_honest_yellow_zone] * 100) if yz_new && yz_new > @p[:max_honest_yellow_zone]
      notes << "n=#{n} < #{@p[:mature_channels]} (maturity) — thin, applied but watch it" if n < @p[:mature_channels]
      [ exists ? :update : :new, notes ]
    end

    # The honest-safety gate has TWO arms and passing EITHER is enough.
    #
    # Absolute: the new ρ_lo leaves at most max_honest_yellow_zone of honest traffic one corroborator
    # away from YELLOW. This is the arm that governs a cell which does not accuse today — an
    # uncalibrated one, where BandClassifier#cell_calibrated? refuses the deficit branch outright.
    # Calibrating it switches accusation ON for the whole cell, so it must clear the bar on its own.
    #
    # Relative: the new ρ_lo does not WIDEN exposure versus the ρ_lo in force right now — the shape of
    # the old workflow's own dryrun gate ("honest AMBER must go DOWN"). Without this arm the gate is
    # perverse: a cell whose stale-high ρ_lo already parks 47% of honest traffic in the deficit zone
    # gets refused a re-seed that would cut it to 18%, purely because 18% is over an absolute bar the
    # cell has been violating for weeks. Refusing to improve a cell is not a safe default; it just
    # leaves the honest channels in it where they are.
    def honest_safe?(yz_now, yz_new)
      return true if yz_new.nil?

      yz_new <= @p[:max_honest_yellow_zone] || (yz_now && yz_new <= yz_now)
    end

    # An uncalibrated cell accuses nobody (cell_calibrated? gates the deficit branch), so its honest
    # YELLOW-zone exposure today is zero whatever its illustrative ρ_lo would arithmetically imply.
    def yellow_zone_now(verdicts, now)
      return verdicts.empty? ? nil : 0.0 unless now.calibrated

      share(verdicts) { |r| r < YELLOW_ZONE * now.rho_lo }
    end

    # applied = the proposal apply would write for this cell (nil → the cell stays as it is now).
    def fleet_effect(fleet_obs, now, applied)
      verdicts = fleet_obs.sum(&:verdicts)
      all = fleet_obs.flat_map(&:rhos)
      full = fleet_obs.select(&:full_tier).flat_map(&:rhos)
      new_star = applied ? applied.rho_star : now.rho_star
      new_lo = applied ? applied.rho_lo : now.rho_lo
      new_cal = applied ? true : now.calibrated
      FleetEffect.new(
        verdicts_per_hour: (verdicts / @p[:fleet_hours].to_f).round(1), judged: all.size,
        amber_now: share(all) { |r| r < GREEN_FLOOR * now.rho_star },
        amber_new: share(all) { |r| r < GREEN_FLOOR * new_star },
        # accusation needs a calibrated cell AND the full tier (BandClassifier cell_calibrated? /
        # accusable_tier?) — share over all judged verdicts, counting only those that could be accused.
        yellow_zone_now: now.calibrated ? share_of(full, all.size) { |r| r < YELLOW_ZONE * now.rho_lo } : (all.empty? ? nil : 0.0),
        yellow_zone_new: new_cal ? share_of(full, all.size) { |r| r < YELLOW_ZONE * new_lo } : (all.empty? ? nil : 0.0)
      )
    end

    # Refuses the whole run — dryrun included, because the dryrun report is what the apply decision is
    # made on — if any current row carries a parent. TrustIndex::V2::CellResolver finishes with
    # `cell.resolved`, which climbs parent_cell while the node is uncalibrated; resolve_now below
    # stops at the "default" category. With a parent in play those two disagree, and then "now" in the
    # diff, honest_below_lo_now and the whole honest-safety gate are measured against a baseline the
    # engine is not using. No live row has one today (that is why resolve_now is allowed to be the
    # simpler thing), so this is a tripwire for the day the hierarchy is actually populated, not a
    # limitation to work around.
    def refuse_parent_cells!(current)
      parented = current.select { |row| row.parent_cell_id.present? }
      return if parented.empty?

      raise Refused, "refusing to run: #{parented.size} current baseline row(s) carry parent_cell_id " \
                     "(#{parented.map { |row| cell_of(row).key }.join('; ')}). CellResolver resolves those up the " \
                     "parent chain and this planner does not, so every diff and safety-gate share for them would " \
                     "be measured against the wrong baseline. Teach resolve_now the chain before re-seeding."
    end

    # Mirrors TrustIndex::V2::CellResolver minus the parent chain: exact cell → "default" category →
    # engine DEFAULT. Safe only because refuse_parent_cells! has already proved no row has a parent.
    def resolve_now(cell)
      row = @current[cell.key] || @current[cell.with(category: "default").key]
      if row
        src = @current[cell.key] ? :exact : :default_category
        return Baseline.new(rho_star: row.rho_star.to_f, rho_lo: row.rho_lo.to_f, rho_hi: row.rho_hi.to_f,
                            sample_size: row.sample_size.to_i, calibrated: row.calibrated == true, source: src)
      end

      d = TrustIndex::ContextBuilder::DEFAULT_CELL_BASELINE
      Baseline.new(rho_star: d.rho_star, rho_lo: d.rho_lo, rho_hi: d.rho_hi, sample_size: 0, calibrated: false,
                   source: :engine_default)
    end

    def index_current(current)
      current.each_with_object({}) { |row, h| h[cell_of(row).key] = row }
    end

    def cell_of(row)
      Cell.new(category: row.category, v_bucket: row.v_bucket, chat_mode: row.chat_mode, language: row.language)
    end

    def quantiles(values)
      s = values.sort
      Proposal.new(rho_star: nearest_rank(s, @p[:p_star]).round(5), rho_lo: nearest_rank(s, @p[:p_lo]).round(5),
                   rho_hi: nearest_rank(s, @p[:p_hi]).round(5), sample_size: s.size)
    end

    # Canon nearest-rank: sorted[round(p·(n−1))] (aggregate_windowed.rb).
    def nearest_rank(sorted, p)
      sorted[(p * (sorted.size - 1)).round]
    end

    def median(values)
      s = values.sort
      n = s.size
      n.odd? ? s[n / 2] : (s[(n / 2) - 1] + s[n / 2]) / 2.0
    end

    def share(values, &pred)
      values.empty? ? nil : values.count(&pred).fdiv(values.size)
    end

    def share_of(values, denominator, &pred)
      denominator.zero? ? nil : values.count(&pred).fdiv(denominator)
    end

    def status_rank(status)
      { update: 0, new: 1, unsafe: 2, held_thin: 3, thin: 4, no_data: 5 }.fetch(status, 9)
    end
  end
end
