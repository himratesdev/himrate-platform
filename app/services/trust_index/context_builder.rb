# frozen_string_literal: true

# TASK-030 FR-003/011: ContextBuilder.
# Collects all data needed for the signals from DB into a single Hash.
# Optimized for 1000+ streams: batch-friendly queries, limited windows, no N+1.
# Each query in rescue — one failure doesn't block the rest.

module TrustIndex
  class ContextBuilder
    CCV_SERIES_LIMIT = 30 # max snapshots for 30min window
    COWINDOW_MINUTES = 60 # TI v2.1 BUG-A trailing window for co-windowed ρ_obs (= chatters window)

    # T1-074 (TI v2) build_v2 constants.
    THIN_SAMPLE_MIN = 30 # < this many present chatters → thin_sample (wider interval, provisional)
    SELF_HISTORY_WINDOW_DAYS = 90 # Rolling Window horizon (30 streams OR 90 days, whichever shorter)
    SELF_HISTORY_WINDOW_STREAMS = 30
    SELF_HISTORY_MIN_CLEAN = 3 # basic tier — ρ_self available once ≥3 clean v2 streams exist
    SELF_HISTORY_STABLE_MIN = 10 # full tier — self-history considered stable
    # EC-18 coarsest fallback: illustrative honest chat-share baseline when no calibration_cell_baseline
    # row resolves (pre-GATE-0 / novel cell). Values from SRS FR-003 example — refined per-cell at GATE 0.
    DEFAULT_CELL_BASELINE = TrustIndex::V2::CellResolver::Baseline.new(rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05)
    V_BUCKETS = [ [ 1_000, "0-1k" ], [ 5_000, "1k-5k" ], [ 20_000, "5k-20k" ] ].freeze

    # Build context Hash for Registry.compute_all
    def self.build(stream)
      channel = stream.channel
      # CR-323 S1: the digest path (fetch_cross_channel) and the temporal path
      # (fetch_temporal_cross_channel_flags) both need the same "pick 500 chatters present in this
      # stream" CH query. Compute it ONCE here and feed both consumers, so the steady-state (both
      # flags ON) does not run the stream_chatters round-trip twice on the SignalComputeWorker hot
      # path — that doubled scan is exactly what BUG-SCW-CROSS-CHANNEL exists to avoid.
      chatters = shared_stream_chatters(stream)

      {
        latest_ccv: fetch_latest_ccv(stream),
        # T1-074 (TI v2, DEC-6): expose the shared present-chatter set so ContextBuilder.build_v2
        # assembles the L0 per-chatter signals from the SAME CH scan — no second stream_chatters
        # round-trip on the shadow/cutover hot path (BUG-SCW-CROSS-CHANNEL discipline).
        stream_chatters: chatters,
        ccv_series_15min: fetch_ccv_series(stream, 15.minutes.ago),
        ccv_series_30min: fetch_ccv_series(stream, 30.minutes.ago),
        ccv_series_10min: fetch_ccv_series(stream, 10.minutes.ago),
        chat_rate_10min: fetch_chat_rate(stream, 10.minutes.ago),
        chat_username_counts_5min: fetch_chat_username_counts(stream, 5.minutes.ago),
        unique_chatters_60min: fetch_unique_chatters(stream),
        # BUG-251.30: registered users present in chat (CommunityTab via Android Client-ID).
        # Source = latest ChattersSnapshot.chatters_present_total. Used by AuthRatio signal #1.
        chatters_present_total: fetch_chatters_present_total(stream),
        bot_scores: fetch_bot_scores(stream),
        channel_protection_config: fetch_config(channel),
        cross_channel_counts: fetch_cross_channel(stream, chatters),
        temporal_cross_channel_flags: fetch_temporal_cross_channel_flags(stream, chatters),
        raids: fetch_raids(stream),
        recent_raids: fetch_recent_raids(stream),
        category: resolve_category(stream),
        stream_duration_min: stream_duration(stream)
      }
    end

    # T1-074 (TI v2, ADR DEC-6): assemble the V2::Engine input Context from the ALREADY-built v1
    # context Hash (reuse — no second CH stream_chatters scan) + a few v2-only reads (known-bot batch,
    # account-profile-less L0 for now, Rolling-Window self-history, cold-start, reputation). Returns
    # a TrustIndex::V2::Engine::Context. Silent sources contribute L_k=0 by design (FR-001 п.2) — only the
    # two SRS-illustrative-LLR sources (temporal_recurrence, known_bot_hit) are wired here; the
    # GATE-0-calibration-pending inputs stay neutral (see PR2b-integration-progress.md source-map).
    def self.build_v2(stream, context_hash)
      channel = stream.channel
      chatters = context_hash[:stream_chatters] || []
      v = context_hash[:latest_ccv]
      cold = TrustIndex::ColdStartGuard.assess(channel)
      q = v2_chatter_quality(chatters, context_hash)
      # Track the calibrated q_mid rather than a literal so the descriptive "high quality" reason-code
      # stays consistent with the band gate (band_classifier uses k.q_mid) after GATE-0 recalibration.
      q_mid = CalibrationConstant.value_for("q_mid", fallback: 0.5).to_f
      # TI v2.1 BUG-A: the co-windowed L2 inputs (both nil when the ti_v2_cowindowed_rho flag is OFF →
      # zero added CH/PG work, engine runs cumulative/instant exactly as today).
      l2_roster, v_w = v2_cowindowed_inputs(stream)

      TrustIndex::V2::Engine::Context.new(
        v: v,
        raw_chatters: v2_chatter_signals(chatters, context_hash),
        cell: v2_cell(stream, context_hash, v),
        **v2_self_history(channel),
        i_event: false, # FR-013 fail-safe (ambiguous ⇒ I=0); full 6-condition conjunction = follow-up
        raid_window: (context_hash[:recent_raids] || []).any?,
        n_chat_eff: chatters.size,
        q: q,
        cold_start_tier: v2_cold_start_tier(cold[:status]),
        chatter_quality_high: q >= q_mid, # descriptive reason-code flag (tracks calibrated q_mid)
        stream_count: cold[:stream_count],
        unattributed_surge: false, # paired with I-event provenance branch = follow-up
        thin_sample: chatters.size < THIN_SAMPLE_MIN,
        reputation: v2_reputation(channel),
        cps: context_hash[:channel_protection_config]&.channel_protection_score&.to_f,
        ccv_chat_divergence: v2_ccv_chat_divergence(context_hash),
        l2_roster_usernames: l2_roster,
        v_w: v_w
      )
    end

    class << self
      private

      def fetch_latest_ccv(stream)
        stream.ccv_snapshots.order(timestamp: :desc).pick(:ccv_count)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: latest_ccv failed (#{e.message})")
        nil
      end

      # BUG-251.30: latest CommunityTab presence count for AuthRatio signal #1.
      # Returns nil if no snapshot has presence column populated (e.g., pre-deploy rows
      # or community_tab batch failed for current cycle) — AuthRatio falls back to insufficient.
      def fetch_chatters_present_total(stream)
        stream.chatters_snapshots
          .where.not(chatters_present_total: nil)
          .order(timestamp: :desc)
          .pick(:chatters_present_total)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: chatters_present_total failed (#{e.message})")
        nil
      end

      def fetch_ccv_series(stream, since)
        stream.ccv_snapshots
          .where("timestamp > ?", since)
          .order(:timestamp)
          .limit(CCV_SERIES_LIMIT)
          .pluck(:ccv_count, :timestamp)
          .map { |ccv, ts| { ccv: ccv, timestamp: ts } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: ccv_series failed (#{e.message})")
        []
      end

      # PR 1e-A (2026-05-31): post-cutover the 4 chat methods read CH only. Dispatch wrapper,
      # PG leaves, dual-read divergence logging, safe_ch shim and summarize/log helpers all
      # deleted — they existed only to validate the CH cutover. Cutover succeeded
      # (2026-05-31T01:33:00Z, ADR addendum), so a single CH read here is the new SoT.
      # Window cutoffs are still floored to the minute (the MVs aggregate at minute granularity).
      def fetch_chat_rate(stream, since)
        Clickhouse::ChatQueries.chat_rate(stream, since.beginning_of_minute)
      end

      # TASK-085 FR-017 (ADR-085 D-7): chat username frequency для Shannon entropy.
      # Used by ChatBehavior signal — entropy < 2.0 → chat_entropy_drop alert.
      def fetch_chat_username_counts(stream, since)
        Clickhouse::ChatQueries.chat_username_counts(stream, since.beginning_of_minute)
      end

      def fetch_unique_chatters(stream)
        Clickhouse::ChatQueries.unique_chatters(stream, 60.minutes.ago.beginning_of_minute)
      end

      def fetch_bot_scores(stream)
        PerUserBotScore
          .where(stream_id: stream.id)
          .pluck(:bot_score, :confidence, :classification, :components)
          .map { |score, conf, cls, comp| { bot_score: score, confidence: conf, classification: cls, components: comp || {} } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: bot_scores failed (#{e.message})")
        []
      end

      def fetch_config(channel)
        channel.channel_protection_config
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: config failed (#{e.message})")
        nil
      end

      # Cross-channel: count distinct channels per username in 24h.
      # Uses chat_messages (works during live, not just post-stream).
      # Limited to stream's chatters to keep query bounded.
      CROSS_CHANNEL_CHATTER_LIMIT = 500

      # BUG-SCW-CROSS-CHANNEL (2026-06-02): the original implementation ran a 24h full-scan of
      # `chat_messages` (5-8s/call, 82-88% of SignalComputeWorker work) — root cause of the
      # :signal_compute backlog. The digest path pre-computes (username → distinct_channels_24h)
      # once per 5min via CrossChannelIntelligenceWorker; the hot read becomes pick-500-chatters
      # (CH, ~0.3-2s) + bulk_lookup (PG, ~5ms) instead of the second join-style 24h scan.
      #
      # Flipper[:cross_channel_digest] gates the new path so we can enable per-env after the
      # refresh worker has populated the digest at least once (cron */5 min), and roll back
      # instantly by disabling the flag if anything regresses.
      #
      # CR-206 Should-2 (preserved on fallback): capture-once `24.hours.ago` so a single absolute
      # timestamp drives the CH query (a server-side `now()` would drift across the 24h boundary).
      # CR-323 S1: the present-chatter set (CH `stream_chatters`, pick 500) shared by the digest +
      # temporal read paths, fetched at most ONCE per build. Skips the CH round-trip entirely when
      # neither path needs it (both flags OFF → the legacy `cross_channel` fallback handles its own).
      def shared_stream_chatters(stream)
        return [] unless Flipper.enabled?(:cross_channel_digest) || Flipper.enabled?(:temporal_cross_channel)

        # Clickhouse::ChatQueries.stream_chatters self-rescues Clickhouse::Error → [] (no extra guard).
        Clickhouse::ChatQueries.stream_chatters(stream)
      end

      def fetch_cross_channel(stream, chatters)
        if Flipper.enabled?(:cross_channel_digest)
          return {} if chatters.empty?

          # CR-258 M1: fetch_with_baseline post-fills single-channel chatters with 1 so the
          # downstream signal's denominator (`cross_channel_counts.size`) stays stable across
          # the Flipper flip — the digest filters `HAVING c > 1` for compactness, not because
          # those chatters don't count.
          CrossChannelDigest.fetch_with_baseline(chatters)
        else
          Clickhouse::ChatQueries.cross_channel(stream, 24.hours.ago.change(usec: 0))
        end
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: cross_channel digest lookup failed (#{e.message})")
        {}
      end

      # T1-057 FR-B2: per-channel temporal cross-channel bot flags for the chatters present in this
      # stream. Gated by Flipper[:temporal_cross_channel] — while OFF this returns {} so the
      # TemporalCrossChannel signal reports insufficient and is EXCLUDED from the weighted TI score
      # (zero regression on existing channels until the signal is deliberately enabled + calibrated).
      # Mirrors the digest read path: stream_chatters (CH) → bulk_lookup (one PG SELECT).
      #
      # Returns { total_chatters:, flagged: } — `total_chatters` (the full present-chatter set) is the
      # signal's DENOMINATOR; `flagged` (R>=2 subset, usually a handful) is the numerator source. Empty
      # ({}) signals insufficient.
      def fetch_temporal_cross_channel_flags(_stream, chatters)
        return {} unless Flipper.enabled?(:temporal_cross_channel)
        return {} if chatters.empty?

        { total_chatters: chatters.size, flagged: CrossChannelTemporalFlag.bulk_lookup(chatters) }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: temporal_cross_channel lookup failed (#{e.message})")
        {}
      end

      def fetch_raids(stream)
        stream.raid_attributions
          .pluck(:timestamp, :is_bot_raid, :raid_viewers_count, :bot_score)
          .map { |ts, bot, viewers, score| { timestamp: ts, is_bot_raid: bot, raid_viewers_count: viewers, bot_score: score } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: raids failed (#{e.message})")
        []
      end

      def fetch_recent_raids(stream)
        stream.raid_attributions
          .where("timestamp > ?", 5.minutes.ago)
          .pluck(:timestamp, :is_bot_raid, :raid_viewers_count)
          .map { |ts, bot, viewers| { timestamp: ts, is_bot_raid: bot, raid_viewers_count: viewers } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: recent_raids failed (#{e.message})")
        []
      end

      def resolve_category(stream)
        Signals::CategoryResolver.resolve(stream.game_name)
      rescue StandardError
        "default"
      end

      def stream_duration(stream)
        ((Time.current - stream.started_at) / 60).to_i
      rescue StandardError
        0
      end

      # === T1-074 (TI v2) build_v2 private assembly ===

      # Per-chatter L0 identity signals. Only the two SRS-illustrative-LLR sources are wired
      # (temporal_recurrence, known_bot_hit); the rest stay neutral (L_k=0 designed, FR-001 п.2) until
      # their GATE-0 calibration lands. Fraud = any flagged tier EXCEPT the "utility" allowlist (i.e.
      # spam OR unknown), mirroring the v1 signal (temporal_cross_channel rejects bot_type=="utility")
      # + the model's BOT_TYPES %w[utility spam unknown]. Counting only "spam" would let an "unknown"
      # tier read clean → nil recurrence AND clean-Q → inflate the GREEN gate: the exact miss TI v2 closes.
      def v2_chatter_signals(chatters, context_hash)
        return [] if chatters.empty?

        flagged = context_hash.dig(:temporal_cross_channel_flags, :flagged) || {}
        known = v2_known_bot_map(chatters)
        chatters.map do |username|
          tf = flagged[username]
          fraud = tf && tf[:bot_type] != "utility"
          TrustIndex::V2::Engine::ChatterSignals.new(
            username: username,
            temporal_recurrence: fraud ? tf[:event_count] : nil,
            known_bot_hit: known[username.to_s.downcase]&.dig(:bot) || false,
            per_user_bot_score: nil,  # old scorer PURGED (SRS §4A.4 #8); new narrow-behavioral L0 = follow-up
            account_profile_llr: 0.0, # GATE-0-calibration-pending (no SRS-specified illustrative LLR yet)
            anti_bot_llr: 0.0,        # no cheap per-chatter roles source; recall-safe neutral
            cluster_delta_k: 0.0,     # community-detection δ_K = follow-up → no density collapse
            cluster_size: 1,
            age_gate: 1.0,            # account-age downweight = follow-up (paired with account_profile)
            recurrence_gate: 1.0
          )
        end
      end

      def v2_known_bot_map(chatters)
        KnownBotService.new.check_batch(chatters)
      rescue StandardError => e
        Rails.logger.warn("ContextBuilder: v2 known_bot batch failed (#{e.message})")
        {}
      end

      # TI v2.1 inflation corroborator (BUG-A/B pivot): REUSE the calibrated v1 CcvChatCorrelation
      # signal (CCV↑ ∧ chat-flat over 10min = silent-viewbot injection — a CCV-SHAPE signature, names
      # nobody). Returns its value (0-1) only when the baseline is confident (ccv_old≥50 ∧ chat_old≥5 →
      # confidence 1.0); low-confidence / insufficient / ccv-decrease → 0.0 (neutral). This feeds L4's
      # C_inflation, the INDEPENDENT second corroborator that lets F_soft's deficit escalate past AMBER
      # (breaking the C_hard monoculture). NOT re-derived — invokes the same signal the v1 registry
      # calibrates (inherits ~5 battle-tested calibration fixes), zero new CH scan (reads the ccv/chat
      # series already in context_hash).
      def v2_ccv_chat_divergence(context_hash)
        res = Signals::CcvChatCorrelation.new.calculate(context_hash)
        return 0.0 unless res && res.confidence.to_f >= 0.5 && res.value

        res.value.to_f
      rescue StandardError => e
        Rails.logger.warn("ContextBuilder: v2 ccv_chat_divergence failed (#{e.message})")
        0.0
      end

      # TI v2.1 BUG-A: the trailing-60min L2 inputs — [windowed_roster_Set, V_W] — for co-windowed ρ_obs.
      # Returns [nil, nil] when the ti_v2_cowindowed_rho flag is OFF (dormant → NO extra CH scan / PG read,
      # engine runs cumulative/instant). The window floor is max(started_at, 60min-ago): a stream <60min
      # old windows to its whole (short) length → windowed roster == cumulative → identical to legacy for
      # young streams (which is why they stop false-AMBERing — the window isn't padded by chatters that
      # left). One bounded stream_chatters_windowed CH round-trip + one ccv_snapshots PG read, flag-ON only.
      def v2_cowindowed_inputs(stream)
        return [ nil, nil ] unless cowindowed_rho_enabled?

        since = [ stream.started_at, COWINDOW_MINUTES.minutes.ago ].max
        # CR must-fix: the roster filter and the V_W denominator MUST flip together. Chat (IRC) and CCV
        # snapshots are separate pipelines, so a stream can have recent chat but a >60min CCV-snapshot
        # gap → v_w nil. Returning [Set, nil] there would half-window (windowed EIHC over an INSTANT-V
        # denominator = an inflated false deficit — the cross-frame confound from the other side, while
        # engine#windowed? reads false). Compute V_W first; if it's absent, stay FULLY dormant.
        v_w = v2_median_ccv_windowed(stream, since)
        return [ nil, nil ] if v_w.nil?

        roster = Clickhouse::ChatQueries.stream_chatters_windowed(stream, since: since).to_set
        [ roster, v_w ]
      rescue StandardError => e
        Rails.logger.warn("ContextBuilder: v2 cowindowed inputs failed (#{e.message})")
        [ nil, nil ]
      end

      def cowindowed_rho_enabled?
        Flipper.enabled?(:ti_v2_cowindowed_rho)
      rescue StandardError
        false
      end

      # P0.5: constrain the self-baseline rows to the ρ_obs convention matching the CURRENT compute
      # mode (same flag that drives v2_cowindowed_inputs). Flag ON → "windowed" rows only. Flag OFF →
      # "cumulative"; NULL (pre-P0.5 rows) reads as cumulative — every pre-P0.5 v2 row predates the
      # flag, so with the flag OFF the selected set is byte-identical to the pre-P0.5 query.
      def self_history_convention_scope(scope)
        if cowindowed_rho_enabled?
          scope.where(rho_convention: "windowed")
        else
          scope.where("rho_convention IS NULL OR rho_convention = ?", "cumulative")
        end
      end

      # V_W = median of the CCV snapshots over the same trailing window (the deficit denominator).
      def v2_median_ccv_windowed(stream, since)
        vals = stream.ccv_snapshots.where("timestamp > ?", since).pluck(:ccv_count).compact.sort
        return nil if vals.empty?

        vals[vals.size / 2]
      end

      # cell = category × V-bucket × chat-mode × language → per-cell ρ* baseline, EC-18 coarsest fallback.
      def v2_cell(stream, context_hash, v)
        TrustIndex::V2::CellResolver.call(
          category: context_hash[:category] || "default",
          v_bucket: v2_v_bucket(v),
          chat_mode: v2_chat_mode(context_hash[:channel_protection_config]),
          language: stream.language.presence || "default"
        ) || DEFAULT_CELL_BASELINE
      rescue StandardError => e
        Rails.logger.warn("ContextBuilder: v2 cell resolve failed (#{e.message})")
        DEFAULT_CELL_BASELINE
      end

      def v2_v_bucket(v)
        return "0" if v.nil? || v <= 0

        V_BUCKETS.each { |ceil, label| return label if v < ceil }
        "20k+"
      end

      def v2_chat_mode(config)
        return "open" unless config
        return "sub-only" if config.subs_only_enabled

        fol = config.followers_only_duration_min
        return "followers-only" if fol && fol >= 0
        return "slow" if config.slow_mode_seconds.to_i.positive?
        return "emote-only" if config.emote_only_enabled

        "open"
      end

      # Q = fraction of present chatters that are temporal-clean = NOT flagged, OR flagged only as the
      # "utility" allowlist (spam/unknown = fraud, mirroring v2_chatter_signals). graph_diversity factor
      # deferred (=1.0) → follow-up. Bot-heavy chat → low Q → GREEN band blocked (correct).
      def v2_chatter_quality(chatters, context_hash)
        return 0.0 if chatters.empty?

        flagged = context_hash.dig(:temporal_cross_channel_flags, :flagged) || {}
        clean = chatters.count { |u| flagged[u].nil? || flagged[u][:bot_type] == "utility" }
        clean.to_f / chatters.size
      end

      # Rolling-Window self-baseline ρ_self_lo (own-P10 of clean-stream ρ_obs, engine_version='v2').
      # Empty pre-backfill ⇒ dormant (clean_self_history false) — F_self never fires. One PG read
      # (DEC-2-sanctioned). F_self also requires I=1 (fail-safe 0 in PR2b) so this is dormant regardless,
      # but the query is the real one for when the I-event computation lands.
      def v2_self_history(channel)
        # P0.5: ρ_self_lo must be built from rows of the SAME ρ_obs convention as the current compute —
        # pooling cumulative + windowed samples corrupts the baseline (see self_history_convention_scope).
        scope = TrustIndexHistory
          .where(channel_id: channel.id, engine_version: "v2", c_hard: false)
          .where("calculated_at > ?", SELF_HISTORY_WINDOW_DAYS.days.ago)
        rows = self_history_convention_scope(scope)
          .order(calculated_at: :desc)
          .limit(SELF_HISTORY_WINDOW_STREAMS)
          .pluck(:rho_obs)
          .compact
          .map(&:to_f)
        return { rho_self_lo: nil, clean_self_history: false, self_history_stable: false } if rows.size < SELF_HISTORY_MIN_CLEAN

        { rho_self_lo: percentile(rows.sort, 0.10),
          clean_self_history: true,
          self_history_stable: rows.size >= SELF_HISTORY_STABLE_MIN }
      rescue StandardError => e
        Rails.logger.warn("ContextBuilder: v2 self-history failed (#{e.message})")
        { rho_self_lo: nil, clean_self_history: false, self_history_stable: false }
      end

      # Nearest-rank percentile on a pre-sorted ascending array (p ∈ [0,1]).
      def percentile(sorted, p)
        return nil if sorted.empty?

        idx = (p * (sorted.size - 1)).round
        sorted[idx]
      end

      def v2_cold_start_tier(status)
        case status
        when "insufficient" then "insufficient"
        when "provisional_low", "provisional" then "basic"
        else "full"
        end
      end

      def v2_reputation(channel)
        Reputation::BandService.cached_for(channel)
      rescue StandardError => e
        Rails.logger.warn("ContextBuilder: v2 reputation failed (#{e.message})")
        nil
      end
    end
  end
end
