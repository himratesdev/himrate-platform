# frozen_string_literal: true

require "rails_helper"

module PersistenceSpecDoubles
  Band = Data.define(:row, :sub, :color)
  Code = Data.define(:code, :params)
  Chatter = Data.define(:username, :p_u)
  Result = Data.define(:erv, :erv_lo, :erv_hi, :f_hat, :f_hard, :f_hard_lo, :f_self, :authenticity,
                       :n_frac, :eihc, :rho_obs, :band, :reason_codes, :c_hard, :c_self,
                       :confirmed_anomaly, :cold_start_tier, :confidence_marker, :b_hard)
end

RSpec.describe TrustIndex::V2::Persistence do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }

  def result(**over)
    base = {
      erv: 2000.4, erv_lo: 1800.6, erv_hi: 2100.2, f_hat: 3000.0, f_hard: 290.0, f_hard_lo: 285.0,
      f_self: 0.0, authenticity: 40.0, n_frac: 0.58, eihc: 45.0, rho_obs: 0.009,
      band: PersistenceSpecDoubles::Band.new(row: 1, sub: nil, color: "red"),
      reason_codes: [ PersistenceSpecDoubles::Code.new(code: "HARD_NAMED_FRACTION", params: { n: 2 }) ],
      c_hard: false, c_self: false, confirmed_anomaly: false, cold_start_tier: "full",
      confidence_marker: "reliable", b_hard: []
    }
    PersistenceSpecDoubles::Result.new(**base.merge(over))
  end

  def persist(res)
    described_class.call(result: res, channel: channel, stream: stream, calculated_at: Time.current)
  end

  it "persists a v2 row (engine_version='v2', NO trust_index_score) — validation passes" do
    tih = persist(result)
    expect(tih.engine_version).to eq("v2")
    expect(tih.trust_index_score).to be_nil
    expect(tih.erv).to eq(2000) # rounded to integer column
    expect(tih.band_row).to eq(1)
    expect(tih.band_color).to eq("red")
    expect(tih.reason_codes.first["code"]).to eq("HARD_NAMED_FRACTION")
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
