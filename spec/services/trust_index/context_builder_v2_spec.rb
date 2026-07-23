# frozen_string_literal: true

require "rails_helper"

# T1-074 PR2b — ContextBuilder.build_v2 assembles the V2::Engine input Context from the ALREADY-built
# v1 context Hash (reuse, no second CH scan) + a few v2-only reads. Verifies the wired vs silent
# source-map (temporal_recurrence + known_bot_hit WIRED; GATE-0-pending sources neutral L_k=0) and
# that the assembled Context drives the real L0→L4 engine end-to-end.
RSpec.describe TrustIndex::ContextBuilder do
  describe ".build_v2" do
    let(:channel) { create(:channel) }
    let(:stream) { create(:stream, channel: channel, language: "ru", game_name: "Dota 2") }

    def ctx_hash(chatters:, flagged: {}, ccv: 5000, config: nil, raids: [], category: "esports")
      {
        latest_ccv: ccv,
        stream_chatters: chatters,
        temporal_cross_channel_flags: { total_chatters: chatters.size, flagged: flagged },
        channel_protection_config: config,
        recent_raids: raids,
        category: category
      }
    end

    def by_name(context)
      context.raw_chatters.to_h { |ch| [ ch.username, ch ] }
    end

    before do
      allow_any_instance_of(KnownBotService).to receive(:check_batch).and_return({})
      allow(Reputation::BandService).to receive(:cached_for)
        .and_return({ band: "stable", tier: "full", stream_count: 20 })
    end

    it "returns a V2::Context of per-chatter ChatterSignals, wired from the shared hash (no re-scan)" do
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a b c]))
      expect(c).to be_a(TrustIndex::V2::Engine::Context)
      expect(c.v).to eq(5000)
      expect(c.raw_chatters.size).to eq(3)
      expect(c.raw_chatters.first).to be_a(TrustIndex::V2::Engine::ChatterSignals)
      expect(c.n_chat_eff).to eq(3)
      expect(c.reputation).to eq({ band: "stable", tier: "full", stream_count: 20 })
    end

    it "BUG-A: co-windowed L2 inputs are nil when ti_v2_cowindowed_rho is OFF (dormant, no added scan)" do
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a b]))
      expect(c.l2_roster_usernames).to be_nil
      expect(c.v_w).to be_nil
    end

    it "BUG-A: co-windowed ON but no windowed CCV snapshot → BOTH inputs nil (no half-windowed frame)" do
      allow(Flipper).to receive(:enabled?).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:ti_v2_cowindowed_rho).and_return(true)
      # the factory stream has no ccv_snapshots in the trailing 60min → v_w nil → roster+v_w paired to nil
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a b]))
      expect(c.l2_roster_usernames).to be_nil
      expect(c.v_w).to be_nil
    end

    it "P1: ContextBuilder.windowed_inputs computes windowed inputs UNCONDITIONALLY (ungated shadow path)" do
      s = create(:stream, channel: channel, language: "ru", started_at: 3.hours.ago)
      # verdict flag OFF, but windowed_inputs is ungated — still [nil, nil] here only because no CCV window.
      expect(described_class.windowed_inputs(s)).to eq([ nil, nil ])
      [ 500, 600, 700 ].each_with_index { |c, i| s.ccv_snapshots.create!(ccv_count: c, timestamp: (i + 1).minutes.ago) }
      allow(Clickhouse::ChatQueries).to receive(:stream_chatters_windowed).and_return(%w[u1 u2 u3])
      roster, v_w = described_class.windowed_inputs(s)
      expect(roster).to eq(Set.new(%w[u1 u2 u3]))
      expect(v_w).to eq(600) # median of 500/600/700 (nearest-rank)
    end

    # TI v2.1 inflation corroborator input: build_v2 reuses the calibrated v1 CcvChatCorrelation
    # signal to compute ccv_chat_divergence (CCV↑ ∧ chat-flat = silent-injection signature).
    it "wires ccv_chat_divergence from CcvChatCorrelation when CCV rises with flat chat" do
      h = ctx_hash(chatters: %w[a]).merge(
        ccv_series_10min: [ { ccv: 100, timestamp: 10.minutes.ago }, { ccv: 200, timestamp: Time.current } ],
        chat_rate_10min: [ { msg_count: 10, timestamp: 10.minutes.ago }, { msg_count: 10, timestamp: Time.current } ]
      )
      expect(described_class.build_v2(stream, h).ccv_chat_divergence).to be > 0.0
    end

    it "ccv_chat_divergence is 0.0 (neutral) when the ccv/chat series are absent — dormant-safe" do
      expect(described_class.build_v2(stream, ctx_hash(chatters: %w[a])).ccv_chat_divergence).to eq(0.0)
    end

    it "wires temporal_recurrence R for fraud tiers (spam AND unknown); only the utility allowlist is excluded" do
      flagged = {
        "botspam" => { bot_flag_tier: "confirmed", bot_type: "spam", event_count: 9, max_concurrent_channels: 12 },
        "unknownbot" => { bot_flag_tier: "flag", bot_type: "unknown", event_count: 4, max_concurrent_channels: 6 },
        "utilitybot" => { bot_flag_tier: "flag", bot_type: "utility", event_count: 5, max_concurrent_channels: 8 }
      }
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[botspam unknownbot utilitybot clean], flagged: flagged))
      chatters = by_name(c)
      expect(chatters["botspam"].temporal_recurrence).to eq(9)
      expect(chatters["unknownbot"].temporal_recurrence).to eq(4)   # unknown = fraud (mirrors v1/model, CR should-fix #1)
      expect(chatters["utilitybot"].temporal_recurrence).to be_nil  # utility allowlist ≠ fraud
      expect(chatters["clean"].temporal_recurrence).to be_nil
    end

    it "wires known_bot_hit from the batch denylist check" do
      allow_any_instance_of(KnownBotService).to receive(:check_batch)
        .and_return({ "knownbot" => { bot: true, confidence: 0.95, sources: %w[a b] } })
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[knownbot clean]))
      chatters = by_name(c)
      expect(chatters["knownbot"].known_bot_hit).to be(true)
      expect(chatters["clean"].known_bot_hit).to be(false)
    end

    it "leaves GATE-0-calibration-pending sources neutral (silent L_k=0, FR-001 п.2)" do
      ch = described_class.build_v2(stream, ctx_hash(chatters: %w[a])).raw_chatters.first
      expect(ch.per_user_bot_score).to be_nil  # old scorer PURGED
      expect(ch.account_profile_llr).to eq(0.0)
      expect(ch.anti_bot_llr).to eq(0.0)
      expect(ch.cluster_delta_k).to eq(0.0)    # no density collapse
      expect(ch.cluster_size).to eq(1)
      expect(ch.age_gate).to eq(1.0)
      expect(ch.recurrence_gate).to eq(1.0)
    end

    it "falls back to the coarsest illustrative cell baseline when no calibration row resolves (EC-18)" do
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a]))
      expect([ c.cell.rho_star, c.cell.rho_lo, c.cell.rho_hi ]).to eq([ 0.03, 0.02, 0.05 ])
    end

    it "Q = fraction of present chatters not spam-temporal-flagged (bot-heavy → low Q)" do
      flagged = { "b1" => { bot_type: "spam", event_count: 5 }, "b2" => { bot_type: "spam", event_count: 5 } }
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[b1 b2 h1 h2], flagged: flagged))
      expect(c.q).to eq(0.5)
      expect(c.chatter_quality_high).to be(true) # 0.5 >= Q_mid threshold
    end

    it "self-history is dormant pre-backfill (no engine_version='v2' rows) → F_self cannot fire" do
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a]))
      expect(c.clean_self_history).to be(false)
      expect(c.rho_self_lo).to be_nil
      expect(c.self_history_stable).to be(false)
    end

    it "computes rho_self_lo from clean v2 history once ≥3 clean rows exist" do
      3.times do |i|
        create(:trust_index_history, channel: channel, stream: create(:stream, channel: channel),
                                     engine_version: "v2", c_hard: false, rho_obs: 0.02 + (i * 0.01),
                                     calculated_at: (i + 1).days.ago)
      end
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a]))
      expect(c.clean_self_history).to be(true)
      expect(c.rho_self_lo).to be_within(0.001).of(0.02)
    end

    it "P0.5: self-baseline segregates by ρ_obs convention — flag ON ignores cumulative rows (no mixing)" do
      # 3 cumulative rows exist (the pre-flip corpus). With the co-windowed flag ON the current compute
      # is 'windowed', so the baseline must NOT be built from cumulative samples → stays dormant.
      3.times do |i|
        create(:trust_index_history, channel: channel, stream: create(:stream, channel: channel),
                                     engine_version: "v2", c_hard: false, rho_obs: 0.02 + (i * 0.01),
                                     rho_convention: "cumulative", calculated_at: (i + 1).days.ago)
      end
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:ti_v2_cowindowed_rho).and_return(true)
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a]))
      expect(c.clean_self_history).to be(false)
      expect(c.rho_self_lo).to be_nil
    end

    it "i_event fail-safe false; raid_window derived from recent_raids" do
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a], raids: [ { timestamp: Time.current } ]))
      expect(c.i_event).to be(false)
      expect(c.raid_window).to be(true)
      expect(c.unattributed_surge).to be(false)
    end

    it "cps read from the stored channel_protection_score" do
      config = ChannelProtectionConfig.create!(channel: channel, channel_protection_score: 42)
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a], config: config))
      expect(c.cps).to eq(42.0)
    end

    it "cold_start_tier maps ColdStartGuard status onto the 3-tier enum" do
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a]))
      expect(%w[insufficient basic full]).to include(c.cold_start_tier)
      expect(c.stream_count).to be_a(Integer)
    end

    it "empty chatter set → n_chat_eff 0, Q 0, thin_sample true (safe degradation)" do
      c = described_class.build_v2(stream, ctx_hash(chatters: []))
      expect(c.raw_chatters).to eq([])
      expect(c.n_chat_eff).to eq(0)
      expect(c.q).to eq(0.0)
      expect(c.thin_sample).to be(true)
    end

    it "V≤0 CCV assembles a Context the engine short-circuits to GREY (EC-15)" do
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a], ccv: nil))
      r = TrustIndex::V2::Engine.compute(context: c, k: Calibration::Registry.load)
      expect(r.erv).to be_nil
      expect(r.band.color).to eq("grey")
    end

    it "wired temporal+known_bot signals reach the engine's hard set end-to-end (recall path proven)" do
      # Clean stub via KnownBotService.new (instance_double) — bypasses the allow_any_instance_of
      # re-stub ambiguity so known_bot_hit is deterministically wired.
      fake_known = instance_double(KnownBotService,
        check_batch: { "megabot" => { bot: true, confidence: 0.95, sources: %w[a b] } })
      allow(KnownBotService).to receive(:new).and_return(fake_known)
      flagged = { "megabot" => { bot_type: "spam", event_count: 9 } }
      chatters = %w[megabot] + Array.new(20) { |i| "h#{i}" }
      c = described_class.build_v2(stream, ctx_hash(chatters: chatters, flagged: flagged, ccv: 500))

      # Wiring proven at the Context level (deterministic, no engine).
      megabot = c.raw_chatters.find { |ch| ch.username == "megabot" }
      expect(megabot.temporal_recurrence).to eq(9)
      expect(megabot.known_bot_hit).to be(true)

      # And the two wired signals cross τ_hard end-to-end under a controlled illustrative k
      # (logit(0.02)+4.6+3.4 = 4.11 → p_u ≈ 0.98 ≥ 0.90). Not Registry.load, to stay threshold-stable.
      k = Calibration::Registry::K.new(
        pi0: 0.02, tau_hard: 0.90, tau_delta: 0.05, phi_yellow: 0.10, phi_red: 0.35,
        q_mid: 0.50, q_hi: 0.80, llr_temporal_r2: 1.10, llr_temporal_r3: 2.20,
        llr_temporal_r4: 2.90, llr_temporal_r7: 4.60, llr_per_user_bot_score: 3.90, llr_known_bot: 3.40,
        phi_inflation: 0.30, inflation_corrob_enabled: 0.0, # TI v2.1 dormant
        i_event_enabled: 0.0, ie_v_trend_z: 99.0, ie_arrival_floor_frac: 0.0, # i_event dormant
        ie_conv_floor: -1.0, ie_cv_floor: 0.0
      )
      r = TrustIndex::V2::Engine.compute(context: c, k: k)
      expect(r.b_hard.map(&:username)).to include("megabot")
      expect(r.engine_version).to eq("v2")
    end

    it "swallows external-source failures without breaking assembly (shadow safety)" do
      allow_any_instance_of(KnownBotService).to receive(:check_batch).and_raise(StandardError, "redis down")
      allow(Reputation::BandService).to receive(:cached_for).and_raise(StandardError, "cache down")
      c = described_class.build_v2(stream, ctx_hash(chatters: %w[a]))
      expect(c).to be_a(TrustIndex::V2::Engine::Context)
      expect(c.raw_chatters.first.known_bot_hit).to be(false)
      expect(c.reputation).to be_nil
    end
  end

  # CR SHOULD-FIX #2: executable coverage of the 4 external-conjunct predicates + helpers (only reachable
  # at i_event_enabled=1.0, which the end-to-end build path never sets). Direct .send tests exercise the
  # crash-safety (nil/empty/degenerate) + FP-safety (never-fire at illustrative floors) claims.
  describe "i_event external-conjunct predicates (crash + FP safety on degenerate data)" do
    def consts(over = {})
      { "i_event_enabled" => 1.0, "ie_v_trend_z" => 99.0, "ie_arrival_floor_frac" => 0.0,
        "ie_conv_floor" => -1.0, "ie_cv_floor" => 0.0 }.merge(over)
    end

    describe "[2] v2_v_above_own_trend?" do
      let(:hist) { Array.new(30) { |i| 100 + i } } # spread present (MAD>0), median ~115, p90 ~126

      it "never fires with <30 clean points (no stable own distribution)" do
        expect(described_class.send(:v2_v_above_own_trend?, 10_000, Array.new(29, 100), consts("ie_v_trend_z" => 1.0))).to be(false)
      end

      it "SF#1a: never fires on a flat (MAD=0) history even under a low z (no robust threshold without spread)" do
        expect(described_class.send(:v2_v_above_own_trend?, 10_000, Array.new(30, 100), consts("ie_v_trend_z" => 1.0))).to be(false)
      end

      it "at the z=99 illustrative default a realistic above-p90 surge does NOT fire (z is the calibration knob)" do
        expect(described_class.send(:v2_v_above_own_trend?, 200, hist, consts)).to be(false) # 200 > p90 but < med+99·MAD
      end

      it "fires when V is a genuine outlier above the own distribution under a calibrated z" do
        expect(described_class.send(:v2_v_above_own_trend?, 10_000, hist, consts("ie_v_trend_z" => 3.0))).to be(true)
      end
    end

    describe "[4] v2_chat_arrival_below_floor?" do
      it "never fires at the 0.0 default (a chat-share is never < 0)" do
        ctx = { chat_username_counts_5min: { "a" => 1, "b" => 2 } }
        expect(described_class.send(:v2_chat_arrival_below_floor?, ctx, 5000, consts)).to be(false)
      end

      it "fires when the recent chat-share is below a calibrated positive floor" do
        ctx = { chat_username_counts_5min: { "a" => 1 } } # 1/5000 = 0.0002
        expect(described_class.send(:v2_chat_arrival_below_floor?, ctx, 5000, consts("ie_arrival_floor_frac" => 0.01))).to be(true)
      end

      it "handles an absent chat map without crashing" do
        expect(described_class.send(:v2_chat_arrival_below_floor?, {}, 5000, consts("ie_arrival_floor_frac" => 0.01))).to be(true)
      end
    end

    describe "[5] v2_no_follower_conversion?" do
      it "fires when a growing channel gains no followers (0 per ccv gained) under a calibrated floor" do
        allow(described_class).to receive(:v2_follower_series).and_return([ 1000, 1000 ]) # d_fol 0
        own_ccv = [ 5000, 5000, 100, 100 ] # recent mean 5000, older 100 → d_ccv +4900
        expect(described_class.send(:v2_no_follower_conversion?, channel, own_ccv, consts("ie_conv_floor" => 0.5))).to be(true)
      end

      it "never fires with <2 follower snapshots" do
        allow(described_class).to receive(:v2_follower_series).and_return([ 1000 ])
        expect(described_class.send(:v2_no_follower_conversion?, channel, [ 5000, 5000, 100, 100 ], consts("ie_conv_floor" => 999))).to be(false)
      end

      it "never fires on a plateaued/declining channel (d_ccv ≤ 0 growth gate — the FP defense)" do
        allow(described_class).to receive(:v2_follower_series).and_return([ 1000, 1000 ])
        own_ccv = [ 100, 100, 5000, 5000 ] # recent mean 100, older 5000 → d_ccv negative
        expect(described_class.send(:v2_no_follower_conversion?, channel, own_ccv, consts("ie_conv_floor" => 999))).to be(false)
      end
    end

    describe "[6] v2_variance_below_floor?" do
      def series(vals)
        { ccv_series_30min: vals.map { |v| { ccv: v } } }
      end

      it "never fires at the 0.0 default (a CoV is never < 0)" do
        expect(described_class.send(:v2_variance_below_floor?, series([ 100, 110, 90, 105, 95 ]), consts)).to be(false)
      end

      it "never fires with <5 points" do
        expect(described_class.send(:v2_variance_below_floor?, series([ 100, 100, 100, 100 ]), consts("ie_cv_floor" => 1.0))).to be(false)
      end

      it "fires when the CoV is below a calibrated floor (pinned/injected CCV)" do
        expect(described_class.send(:v2_variance_below_floor?, series([ 1000, 1001, 999, 1000, 1000 ]), consts("ie_cv_floor" => 0.1))).to be(true)
      end

      it "handles an empty series without crashing" do
        expect(described_class.send(:v2_variance_below_floor?, { ccv_series_30min: [] }, consts("ie_cv_floor" => 1.0))).to be(false)
      end
    end

    it "v2_follower_series returns newest-first counts within the conversion window" do
      FollowerSnapshot.create!(channel: channel, timestamp: 1.day.ago, followers_count: 1000)
      FollowerSnapshot.create!(channel: channel, timestamp: 3.days.ago, followers_count: 900)
      FollowerSnapshot.create!(channel: channel, timestamp: 30.days.ago, followers_count: 100) # outside 7d
      expect(described_class.send(:v2_follower_series, channel)).to eq([ 1000, 900 ])
    end

    it "median_abs_deviation is 0 on a flat set, positive on a spread set" do
      expect(described_class.send(:median_abs_deviation, [ 5, 5, 5, 5 ], 5)).to eq(0)
      expect(described_class.send(:median_abs_deviation, [ 1, 2, 3, 4, 5 ], 3)).to be > 0
    end
  end
end
