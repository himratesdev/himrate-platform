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
        llr_temporal_r4: 2.90, llr_temporal_r7: 4.60, llr_per_user_bot_score: 3.90, llr_known_bot: 3.40
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
end
