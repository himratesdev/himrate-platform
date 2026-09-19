# frozen_string_literal: true

require "rails_helper"

module PersistenceSpecDoubles
  Band = Data.define(:row, :sub, :color)
  Code = Data.define(:code, :params)
  Chatter = Data.define(:username, :p_u)
  Result = Data.define(:erv, :erv_lo, :erv_hi, :f_hat, :f_hat_lo, :f_hat_hi, :f_hard, :f_hard_lo, :f_hard_hi,
                       :f_self,
                       :f_soft, :f_soft_lo, :f_soft_hi, :authenticity, :authenticity_lo, :authenticity_hi,
                       :n_frac, :q_score, :eihc, :rho_obs, :rho_convention, :band, :reason_codes, :c_hard, :c_self,
                       # DETECTION-AUDIT 2026-09-19 — the rest of the corroboration set + the quantities
                       # the verdict turned on (columns that existed but had no writer).
                       :c_inflation, :c_hard_abs, :c_pop, :n_chat_eff, :cps, :rho_self, :rho_self_lo,
                       :confirmed_anomaly, :cold_start_tier, :confidence_marker, :b_hard)
end

RSpec.describe TrustIndex::V2::Persistence do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }

  def result(**over)
    base = {
      erv: 2000.4, erv_lo: 1800.6, erv_hi: 2100.2, f_hat: 3000.0, f_hat_lo: 2900.0, f_hat_hi: 3100.0,
      f_hard: 290.0, f_hard_lo: 285.0, f_hard_hi: 295.0, f_self: 0.0,
      c_inflation: false, c_hard_abs: false, c_pop: false, n_chat_eff: 420, cps: 65,
      rho_self: 0.12, rho_self_lo: 0.09,
      f_soft: 3000.0, f_soft_lo: 2800.0, f_soft_hi: 3200.0,
      authenticity: 40.0, authenticity_lo: 38.0, authenticity_hi: 42.0, n_frac: 0.58, q_score: 0.73,
      eihc: 45.0, rho_obs: 0.009, rho_convention: "cumulative",
      band: PersistenceSpecDoubles::Band.new(row: 1, sub: nil, color: "red"),
      reason_codes: [ PersistenceSpecDoubles::Code.new(code: "HARD_NAMED_FRACTION", params: { n: 2 }) ],
      c_hard: false, c_self: false, confirmed_anomaly: false, cold_start_tier: "full",
      confidence_marker: "reliable", b_hard: []
    }
    PersistenceSpecDoubles::Result.new(**base.merge(over))
  end

  def persist(res, ccv: nil)
    described_class.call(result: res, channel: channel, stream: stream, calculated_at: Time.current, ccv: ccv)
  end

  it "persists ccv (the engine input V) when provided — PR3b gap D-5" do
    expect(persist(result, ccv: 4200).ccv).to eq(4200)
    expect(persist(result).ccv).to be_nil
  end

  it "persists a v2 row (engine_version='v2', NO trust_index_score) — validation passes" do
    tih = persist(result)
    expect(tih.engine_version).to eq("v2")
    expect(TrustIndexHistory.column_names).not_to include("trust_index_score") # V1-RETIRE: column dropped
    expect(tih.erv).to eq(2000) # rounded to integer column
    expect(tih.band_row).to eq(1)
    expect(tih.band_color).to eq("red")
    expect(tih.reason_codes.first["code"]).to eq("HARD_NAMED_FRACTION")
    expect(tih.i_event).to be(false) # mirrors c_self (false here)
  end

  it "writes the i_event column to mirror C_self (I=1) — not left at the NOT NULL default" do
    expect(persist(result(c_self: true)).i_event).to be(true)
  end

  it "persists tiny-V rho_obs >= 10 (ρ = EIHC/V, V=1-2 live channels) — numeric(8,5) regression guard" do
    # pre-widening numeric(6,5) overflowed at ρ >= 10 → SCW retry-looped on PG::NumericValueOutOfRange
    # and tiny-V streams never got a v2 row (post-flip incident 2026-07-21). Bound: roster cap 500 / V>=1.
    expect(persist(result(rho_obs: 437.5)).reload.rho_obs).to eq(437.5)
  end

  it "persists rho_obs >= 1000 (BUG-EIHC-500CAP: scaled EIHC ≤ n_roster is uncapped; tiny-V snapshot " \
     "on a big-roster channel) — numeric(12,5) regression guard" do
    # scaled EIHC removed the ρ ≤ 500 bound numeric(8,5) was sized under (migration 20260805210000):
    # v_eff = 1-2 (glitchy/pre-offline latest CCV) × windowed n_roster ≥ 1000 → ρ_obs ≥ 1000. The SCW
    # cutover path has no rescue — an overflow here is dead jobs / lost verdicts, not a log line.
    expect(persist(result(rho_obs: 1825.0)).reload.rho_obs).to eq(1825.0)
    expect(persist(result(rho_obs: 8768.43210)).reload.rho_obs).to eq(8768.4321)
  end

  it "stamps rho_convention (P0.5) so the self-baseline + ρ* miner segregate cumulative vs windowed" do
    expect(persist(result).rho_convention).to eq("cumulative")
    expect(persist(result(rho_convention: "windowed")).rho_convention).to eq("windowed")
  end

  it "persists the PR3a soft breakdown + intervals + Q (gap D-3) so /erv erv_breakdown has f_soft" do
    tih = persist(result)
    expect(tih.f_soft).to eq(3000.0)
    expect(tih.f_soft_lo).to eq(2800.0)
    expect(tih.f_soft_hi).to eq(3200.0)
    expect(tih.f_hat_lo).to eq(2900.0)
    expect(tih.f_hat_hi).to eq(3100.0)
    expect(tih.authenticity_lo).to eq(38.0)
    expect(tih.authenticity_hi).to eq(42.0)
    expect(tih.q_score).to eq(0.73)
  end

  # DETECTION-AUDIT 2026-09-19 (ENGINE-RCA Q2): a YELLOW/RED decided by C_inflation, the integer
  # named-count trigger or C_pop persisted with c_hard=c_self=false and read back as an accusation
  # with no corroborator at all — the audit had to re-derive the path from the reason codes.
  describe "corroboration-path observability" do
    it "persists every path the plashka reads, not just c_hard/c_self" do
      tih = persist(result(c_inflation: true, c_hard_abs: false, c_pop: true, confirmed_anomaly: true))
      expect([ tih.c_inflation, tih.c_hard_abs, tih.c_pop ]).to eq([ true, false, true ])
    end

    it "leaves a path NULL when it was never evaluated (EC-15 V≤0 skeleton) — NULL ≠ false" do
      tih = persist(result(c_inflation: nil, c_hard_abs: nil, c_pop: nil, n_chat_eff: nil))
      expect([ tih.c_inflation, tih.c_hard_abs, tih.c_pop, tih.n_chat_eff ]).to all(be_nil)
    end

    it "persists the quantities the verdict turned on (roster, CPS, self-baseline, F_hard P95)" do
      tih = persist(result).reload
      expect(tih.n_chat_eff).to eq(420)  # the N_frac denominator — the number the accusation divides by
      expect(tih.cps).to eq(65)
      expect(tih.rho_self).to eq(0.12)
      expect(tih.rho_self_lo).to eq(0.09)
      expect(tih.f_hard_hi).to eq(295.0)
    end
  end

  it "writes a named_bot_evidence row per B_hard account when C_hard fires (EC-13)" do
    b_hard = [ PersistenceSpecDoubles::Chatter.new(username: "botA", p_u: 0.97),
               PersistenceSpecDoubles::Chatter.new(username: "botB", p_u: 0.94) ]
    tih = persist(result(c_hard: true, confirmed_anomaly: true, b_hard: b_hard))
    evidence = NamedBotEvidence.for_history(tih.id)
    expect(evidence.pluck(:username)).to contain_exactly("botA", "botB")
    expect(evidence.first.p_u).to eq(0.97) # ordered by p_u desc
  end

  it "does NOT write evidence when C_hard is false (no plashka backing needed)" do
    tih = persist(result(c_hard: false, b_hard: []))
    expect(NamedBotEvidence.where(trust_index_history_id: tih.id)).to be_empty
  end

  # PR3b MF-1 follow-up: delta-write — repeat computes with the SAME named set write ZERO rows;
  # set growth writes only the NEW accounts, tied to the snapshot where they first appeared.
  describe "evidence delta-write (write-amplification guard)" do
    let(:bots_ab) do
      [ PersistenceSpecDoubles::Chatter.new(username: "botA", p_u: 0.97),
        PersistenceSpecDoubles::Chatter.new(username: "botB", p_u: 0.94) ]
    end

    it "same-set repeat compute writes no new evidence rows" do
      persist(result(c_hard: true, confirmed_anomaly: true, b_hard: bots_ab))
      expect {
        persist(result(c_hard: true, confirmed_anomaly: true, b_hard: bots_ab))
      }.not_to change(NamedBotEvidence, :count)
    end

    it "set growth writes ONLY the delta, linked to the current snapshot" do
      persist(result(c_hard: true, confirmed_anomaly: true, b_hard: bots_ab))
      grown = bots_ab + [ PersistenceSpecDoubles::Chatter.new(username: "botC", p_u: 0.92) ]
      tih2 = nil
      expect {
        tih2 = persist(result(c_hard: true, confirmed_anomaly: true, b_hard: grown))
      }.to change(NamedBotEvidence, :count).by(1)
      expect(NamedBotEvidence.where(trust_index_history_id: tih2.id).pluck(:username)).to eq([ "botC" ])
    end
  end
end
