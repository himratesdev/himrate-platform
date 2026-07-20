# frozen_string_literal: true

require "rails_helper"

module PersistenceSpecDoubles
  Band = Data.define(:row, :sub, :color)
  Code = Data.define(:code, :params)
  Chatter = Data.define(:username, :p_u)
  Result = Data.define(:erv, :erv_lo, :erv_hi, :f_hat, :f_hat_lo, :f_hat_hi, :f_hard, :f_hard_lo, :f_self,
                       :f_soft, :f_soft_lo, :f_soft_hi, :authenticity, :authenticity_lo, :authenticity_hi,
                       :n_frac, :q_score, :eihc, :rho_obs, :band, :reason_codes, :c_hard, :c_self,
                       :confirmed_anomaly, :cold_start_tier, :confidence_marker, :b_hard)
end

RSpec.describe TrustIndex::V2::Persistence do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }

  def result(**over)
    base = {
      erv: 2000.4, erv_lo: 1800.6, erv_hi: 2100.2, f_hat: 3000.0, f_hat_lo: 2900.0, f_hat_hi: 3100.0,
      f_hard: 290.0, f_hard_lo: 285.0, f_self: 0.0,
      f_soft: 3000.0, f_soft_lo: 2800.0, f_soft_hi: 3200.0,
      authenticity: 40.0, authenticity_lo: 38.0, authenticity_hi: 42.0, n_frac: 0.58, q_score: 0.73,
      eihc: 45.0, rho_obs: 0.009,
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
    expect(tih.trust_index_score).to be_nil
    expect(tih.erv).to eq(2000) # rounded to integer column
    expect(tih.band_row).to eq(1)
    expect(tih.band_color).to eq("red")
    expect(tih.reason_codes.first["code"]).to eq("HARD_NAMED_FRACTION")
    expect(tih.i_event).to be(false) # mirrors c_self (false here)
  end

  it "writes the i_event column to mirror C_self (I=1) — not left at the NOT NULL default" do
    expect(persist(result(c_self: true)).i_event).to be(true)
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
end
