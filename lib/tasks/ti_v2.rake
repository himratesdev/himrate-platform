# frozen_string_literal: true

# FULL-CHAIN M1 (2026-07-27) — ops verification of the L0 naming-stack invariants on the LIVE,
# DB-merged calibration table (Calibration::Registry.load reads CalibrationConstant overrides). The
# rspec suite (spec/services/calibration/llr_naming_invariants_spec.rb) asserts the SAME bounds on the
# illustrative floor; this task asserts them on whatever a flip's data-write actually produced. Run it
# in EVERY LLR flip runbook, AFTER seeding, BEFORE declaring the flip done: a bad seed that stacks a
# sub-confirmed temporal tier into public naming exits non-zero here (fail-loud), never in production.
# CR P2 iter-1 (SF3): helpers extracted from `def`s inside the `task do` blocks — those define
# methods on Object and leak into every process that loads the tasks (rspec included), and the
# task-local UPPERCASE names were top-level constants that reassigned on repeat invoke. The task
# bodies below stay byte-close to the workflow heredocs; only the call sites gained a `tv.` receiver.
module TiV2Calibration
  module_function

  def pct(a, p)
    return nil if a.nil? || a.empty?
    s = a.sort
    s[[ (p * (s.size - 1)).round, s.size - 1 ].min]
  end

  def vbucket(v)
    return "0" if v.nil? || v <= 0
    return "0-1k" if v < 1000
    return "1k-5k" if v < 5000
    return "5k-20k" if v < 20000
    "20k+"
  end

  def chat_mode(cfg)
    return "open" unless cfg
    return "sub-only" if cfg.subs_only_enabled
    fol = cfg.followers_only_duration_min
    return "followers-only" if fol && fol >= 0
    return "slow" if cfg.slow_mode_seconds.to_i.positive?
    return "emote-only" if cfg.emote_only_enabled
    "open"
  end

  def amber(bands) = bands.select { |k, _| k.start_with?("amber") }.values.sum

  def accus(bands) = bands.select { |k, _| k.start_with?("red") || k.start_with?("yellow") }.values.sum

  # Live honest RU cohort band mix via the REAL engine (reads the seeded cells through Registry/cell
  # resolver). c_hard=false honest anchors only. Returns [band_mix, n].
  def honest_scan(n_target)
    cb = TrustIndex::ContextBuilder
    live = Stream.where(ended_at: nil).where(language: "RU").order(started_at: :desc).limit(1000).to_a
    bands = Hash.new(0); n = 0
    live.each do |s|
      break if n >= n_target
      t = TrustIndexHistory.where(stream_id: s.id, engine_version: "v2").order(calculated_at: :desc).first
      next unless t && t.c_hard == false
      ctx = cb.build(s)
      roster, v_w, n_w = cb.windowed_inputs(s)
      v2c = cb.build_v2(s, ctx)
      next if v2c.v.nil? || v2c.v <= 0
      wctx = v_w ? v2c.with(l2_roster_usernames: roster, v_w: v_w, n_roster: n_w) : v2c
      res = TrustIndex::V2::Engine.compute(context: wctx, k: Calibration::Registry.load)
      bands["#{res.band&.color}/#{res.band&.row}"] += 1
      n += 1
    rescue StandardError
      nil
    end
    [ bands, n ]
  end

  def upsert!(rows)
    rows.each do |r|
      b = CalibrationCellBaseline.find_or_initialize_by(
        category: r["cat"], v_bucket: r["vb"], chat_mode: r["cm"], language: r["lang"]
      )
      b.assign_attributes(rho_star: r["star"], rho_lo: r["lo"], rho_hi: r["hi"],
                          sample_size: r["n"], calibrated: true)
      b.save!
    end
  end
end

namespace :ti_v2 do
  desc "Verify the L0 LLR naming-stack invariants (I1/I2/I3) on the live DB-merged table"
  task verify_llr_invariants: :environment do
    k = Calibration::Registry.load
    tau_gap = Math.log(k.tau_hard / (1.0 - k.tau_hard)) - Math.log(k.pi0 / (1.0 - k.pi0))

    # Each check: [label, lhs, rhs] — the invariant is lhs < rhs (all three are strict "must-not-name" bounds).
    checks = [
      [ "I1  R2+known < τ_gap", k.llr_temporal_r2 + k.llr_known_bot, tau_gap ],
      [ "I2  R3+known < τ_gap", k.llr_temporal_r3 + k.llr_known_bot, tau_gap ],
      [ "I3  R4 solo  < τ_gap−1", k.llr_temporal_r4,                tau_gap - 1.0 ]
    ]

    puts "== L0 LLR naming-stack invariants (live) == τ_gap=#{tau_gap.round(3)} (π0=#{k.pi0} τ_hard=#{k.tau_hard})"
    puts "   LLR table: r2=#{k.llr_temporal_r2} r3=#{k.llr_temporal_r3} r4=#{k.llr_temporal_r4} r7=#{k.llr_temporal_r7} known=#{k.llr_known_bot}"
    failed = checks.reject do |label, lhs, rhs|
      ok = lhs < rhs
      puts format("   %-22s %.3f < %.3f  → %s", label, lhs, rhs, ok ? "PASS" : "🔴 FAIL")
      ok
    end

    # Informational: r7 is the INTENDED solo-naming tier; at the illustrative default (4.60) it sits BELOW
    # τ_gap (calibration-pending), while the live GATE-0 seed (6.2) crosses it. Report the real state, don't gate.
    r7_names = k.llr_temporal_r7 >= tau_gap
    puts format("   r7 solo naming tier    %.3f %s %.3f  → %s",
                k.llr_temporal_r7, r7_names ? "≥" : "<", tau_gap,
                r7_names ? "names (R7 crosses τ_gap)" : "BELOW-naming (illustrative default / calibration-pending)")

    if failed.any?
      warn "\n🔴 #{failed.size} naming-stack invariant(s) VIOLATED — a sub-confirmed tier can name. DO NOT proceed with the flip."
      exit 1
    end
    puts "\n🟢 all naming-stack invariants hold — no accidental naming class."
  end
end

namespace :ti_v2 do
  # P2 2026-09-02: the GATE-0 calibration scripts used to live as YAML heredocs inside
  # .github/workflows/ti-v2-{shadow-mine,rho-reseed}.yml (scp'd to /tmp and run via
  # `rails runner`) — unrunnable without GitHub and invisible to specs. Ported here VERBATIM;
  # the workflows are now thin wrappers (`docker exec … bin/rails ti_v2:…` with the same ENV).
  #
  # ti_v2:shadow_mine — mine `SCW shadow` log lines into the per-cell ρ* seed table.
  #   ENV: SHADOW_LINES (path, default /tmp/shadow_lines.txt) · MINE_CONV (cumulative|windowed).
  desc "Mine SCW shadow log lines into per-cell rho* seeds (ENV: SHADOW_LINES, MINE_CONV)"
  task shadow_mine: :environment do
    $stdout.sync = true
    require "json"
    require "set"

    tv = TiV2Calibration
    # P0.5: pool ONLY one ρ_obs convention (cumulative vs windowed) — mixing corrupts ρ*. Pre-P0.5
    # shadow lines have no v2_rho_conv key → treated as "cumulative" (they predate the flag).
    wanted_conv = ENV.fetch("MINE_CONV", "cumulative")

    # ===== parse shadow lines → per-stream samples =====
    samples = Hash.new { |h, k| h[k] = { rho: [], v: [], div: [] } }
    total = 0; usable = 0; skipped_conv = 0
    File.foreach(ENV.fetch("SHADOW_LINES", "/tmp/shadow_lines.txt")) do |line|
      total += 1
      i = line.index("SCW shadow ")
      next unless i
      j = JSON.parse(line[(i + 11)..]) rescue next
      rho = j["v2_rho_obs"]
      next if rho.nil? || rho.to_f <= 0 # pre-#384 lines / offline streams — skip
      conv = j["v2_rho_conv"] || "cumulative" # P0.5: nil = pre-stamp line = cumulative
      (skipped_conv += 1; next) unless conv == wanted_conv
      sid = j["stream_id"]
      next unless sid
      samples[sid][:rho] << rho.to_f
      samples[sid][:v] << j["v2_v"].to_f if j["v2_v"]
      # phi_inflation calibration: the corroborator (CcvChatCorrelation) value per SCW cycle.
      samples[sid][:div] << j["v2_ccv_chat_divergence"].to_f if j["v2_ccv_chat_divergence"]
      usable += 1
    end
    puts "convention filter: WANTED=#{wanted_conv} (skipped #{skipped_conv} other-convention lines)"
    puts "shadow lines: #{total} total, #{usable} usable, #{samples.size} distinct streams"

    # ===== honest-anchor filter (mirrors ti-v2-rho-build hygiene) =====
    cell_rho = Hash.new { |h, k| h[k] = [] }
    all_rho = []
    anchor_div_max = [] # phi_inflation: per-honest-anchor MAX ccv_chat_divergence (C_inflation fires on the moment)
    kept = 0; rejected = { not_found: 0, not_partner: 0, few_streams: 0, low_ti: 0, anomaly: 0, spam: 0, no_roster: 0 }
    samples.each do |sid, data|
      s = Stream.find_by(id: sid)
      (rejected[:not_found] += 1; next) unless s
      ch = s.channel
      (rejected[:not_partner] += 1; next) unless ch.broadcaster_type == "partner"
      (rejected[:few_streams] += 1; next) if Stream.where(channel_id: ch.id).where.not(ended_at: nil).count < 10
      # engine-aware: post-cutover latest rows are v2 (trust_index_score nil, authenticity set)
      ti = TrustIndexHistory.where(channel_id: ch.id).order(calculated_at: :desc).limit(1)
                            .pick(Arel.sql("CASE WHEN engine_version = 'v2' THEN authenticity ELSE trust_index_score END"))
      (rejected[:low_ti] += 1; next) if ti.nil? || ti.to_f < 88
      anom = Anomaly.where(anomaly_type: %w[viewbot_spike ccv_step_function], stream_id: sid)
                    .where("timestamp > ?", 24.hours.ago).exists?
      (rejected[:anomaly] += 1; next) if anom && !RaidAttribution.where(stream_id: sid).exists?
      roster = (Clickhouse::ChatQueries.stream_chatters(s) rescue [])
      (rejected[:no_roster] += 1; next) if roster.empty?
      flagged = CrossChannelTemporalFlag.bulk_lookup(roster)
      spam = flagged.reject { |_, d| d[:bot_type] == "utility" }
      (rejected[:spam] += 1; next) if spam.size.to_f / roster.size > 0.05

      rho_med = tv.pct(data[:rho], 0.50)
      v_med = tv.pct(data[:v], 0.50) || 0
      cat = (TrustIndex::Signals::CategoryResolver.resolve(s.game_name) rescue "default")
      cell = [ cat, tv.vbucket(v_med), tv.chat_mode(ch.channel_protection_config), (s.language.presence || "default") ].join("|")
      cell_rho[cell] << rho_med
      all_rho << rho_med
      # phi_inflation: the honest anchor's PEAK divergence over the window (0 if the corroborator
      # never signalled). C_inflation fires on the transient max, so the max — not the median — is
      # what phi_inflation must clear on honest channels.
      dmax = data[:div].max
      anchor_div_max << dmax if dmax
      puts format("RAW %s %s %.5f (n_samples=%d) div_max=%.4f", ch.login, cell, rho_med, data[:rho].size, dmax || 0.0)
      kept += 1
    rescue => e
      nil
    end
    puts "\nanchors kept: #{kept} | rejected: #{rejected.map { |k, v| "#{k}=#{v}" }.join(' ')}"

    # ===== per-cell seed table =====
    puts "\n===== SHADOW-MINED ρ* PER CELL (n>=3; SEED format) ====="
    cell_rho.select { |_, a| a.size >= 3 }.sort_by { |_, a| -a.size }.each do |cell, a|
      cat, vb, cm, lang = cell.split("|")
      puts format("  [ %-16s %-8s %-16s %-6s ] n=%-3d ρ*=%.4f ρ_lo=%.4f ρ_hi=%.4f",
                  "\"#{cat}\",", "\"#{vb}\",", "\"#{cm}\",", "\"#{lang}\",", a.size, # lang VERBATIM — the .downcase cosmetic caused the ru/RU seed-miss bug
                  tv.pct(a, 0.50), tv.pct(a, 0.10), tv.pct(a, 0.90))
    end
    puts "\nGLOBAL: n=#{all_rho.size} ρ_lo=#{tv.pct(all_rho, 0.10)&.round(4)} ρ*=#{tv.pct(all_rho, 0.50)&.round(4)} ρ_hi=#{tv.pct(all_rho, 0.90)&.round(4)}"
    puts "→ pool the n>=8 rows into verivio-clode/_tasks/T1-074/rho-raw/ (aggregate_windowed.rb) → CELLS_JSON for ti_v2:rho_reseed."

    # ===== phi_inflation calibration: honest-anchor divergence distribution =====
    # The inflation corroborator (dormant) fires when ccv_chat_divergence >= phi_inflation (∧ ¬raid).
    # Honest anchors have natural non-raid CCV surges with flat chat (embeds / front-page) → nonzero
    # divergence. phi_inflation must sit ABOVE the honest P99-of-max so honest channels ~never trip.
    puts "\n===== HONEST-ANCHOR ccv_chat_divergence DISTRIBUTION (phi_inflation calibration) ====="
    nz = anchor_div_max.reject(&:zero?)
    puts "  honest anchors: #{anchor_div_max.size} | with any divergence (>0): #{nz.size}"
    if anchor_div_max.any?
      puts format("  per-anchor MAX divergence: P50=%.4f P90=%.4f P95=%.4f P99=%.4f max=%.4f",
                  tv.pct(anchor_div_max, 0.50) || 0, tv.pct(anchor_div_max, 0.90) || 0, tv.pct(anchor_div_max, 0.95) || 0,
                  tv.pct(anchor_div_max, 0.99) || 0, anchor_div_max.max || 0)
      [ 0.2, 0.3, 0.5 ].each do |phi|
        trip = anchor_div_max.count { |d| d >= phi }
        puts format("  phi_inflation=%.2f → %d/%d honest anchors TRIP C_inflation (%.1f%% honest false-positive)",
                    phi, trip, anchor_div_max.size, 100.0 * trip / anchor_div_max.size)
      end
      puts "  → set phi_inflation ABOVE honest P99; bring to PO before the flip."
    else
      puts "  no honest-anchor divergence samples yet (need accrued shadow lines carrying v2_ccv_chat_divergence)"
    end
  end

  # ti_v2:rho_reseed — windowed per-cell ρ* re-seed with dryrun honest-impact gate / apply
  #   auto-rollback. ENV: RESEED_MODE (dryrun|apply) · HONEST_SAMPLE · CELLS_JSON (required).
  desc "Windowed rho* re-seed, dryrun gate / apply auto-rollback (ENV: RESEED_MODE, HONEST_SAMPLE, CELLS_JSON)"
  task rho_reseed: :environment do
    $stdout.sync = true
    require "json"
    tv   = TiV2Calibration
    mode = ENV.fetch("RESEED_MODE", "dryrun")
    hn   = ENV.fetch("HONEST_SAMPLE", "80").to_i.clamp(20, 300)
    rows = JSON.parse(ENV.fetch("CELLS_JSON", "[]")) rescue []
    abort "no cells provided (cells_json empty)" if rows.empty?


    puts "===== ρ* RE-SEED windowed MODE=#{mode} — #{rows.size} cells @ #{Time.current.iso8601} ====="
    rows.each { |r| puts "  #{r['cat']}|#{r['vb']}|#{r['cm']}|#{r['lang']} → rho*=#{r['star']} lo=#{r['lo']} hi=#{r['hi']} n=#{r['n']}" }

    if mode == "dryrun"
      before, nb = tv.honest_scan(hn)
      ActiveRecord::Base.transaction do
        tv.upsert!(rows)
        after, na = tv.honest_scan(hn)
        puts "\n-- honest band mix BEFORE: #{before.sort_by { |_, v| -v }.to_h} (n=#{nb})"
        puts "-- honest band mix AFTER (simulated, rolls back): #{after.sort_by { |_, v| -v }.to_h} (n=#{na})"
        puts "-- honest AMBER #{tv.amber(before)}→#{tv.amber(after)} (want DOWN — false-AMBER cleanup); honest RED/YELLOW after=#{tv.accus(after)} (want 0)"
        safe = tv.amber(after) <= tv.amber(before) && tv.accus(after) == 0
        puts(safe ? "\n✅ DRYRUN SAFE → dispatch MODE=apply" : "\n🔴 DRYRUN UNSAFE (honest not improved / accused) → DO NOT apply; investigate")
        raise ActiveRecord::Rollback
      end
    else
      # snapshot prior values (nil = new cell) for rollback
      snap = rows.map do |r|
        c = CalibrationCellBaseline.find_by(category: r["cat"], v_bucket: r["vb"], chat_mode: r["cm"], language: r["lang"])
        [ r, c && { rho_star: c.rho_star, rho_lo: c.rho_lo, rho_hi: c.rho_hi, sample_size: c.sample_size, calibrated: c.calibrated } ]
      end
      tv.upsert!(rows)
      after, na = tv.honest_scan(hn)
      puts "\n-- POST-RESEED honest band mix: #{after.sort_by { |_, v| -v }.to_h} (n=#{na}); honest RED/YELLOW=#{tv.accus(after)}"
      if tv.accus(after) > [ (0.02 * na).ceil, 1 ].max
        snap.each do |r, prev|
          c = CalibrationCellBaseline.find_by(category: r["cat"], v_bucket: r["vb"], chat_mode: r["cm"], language: r["lang"])
          next unless c
          prev ? c.update!(prev) : c.update!(calibrated: false) # new cell → un-calibrate (never accuse off it)
        end
        puts "\n== 🔴 AUTO-ROLLBACK: #{tv.accus(after)} honest accused → reverted #{rows.size} cells. Investigate. =="
      else
        puts "\n== 🟢 RE-SEED APPLIED: #{rows.size} cells calibrated, honest RED/YELLOW=#{tv.accus(after)} (~0)."
        puts "   NEXT: STRICT live-verify (honest RU GREEN + dariya labeled-botter deficit) + C_pop quantiles"
        puts "   (rho_p1=P5-margin@n≥150 + ccv_typical) — needs a miner harvest change (gate0-seed/ti-v2-anchor-rho)."
      end
    end
  end
end
