# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trust::Explanation do
  let(:channel) { create(:channel) }
  let!(:stream) { create(:stream, channel: channel, game_name: "Just Chatting", language: "ru") }

  def snapshot(**attrs)
    create(:trust_index_history, {
      channel: channel, stream: stream, engine_version: "v2",
      ccv: 1_240, erv: 750, erv_lo: 620, erv_hi: 880,
      authenticity: 60.5, authenticity_lo: 50.0, authenticity_hi: 71.0,
      f_hard: 180.0, f_hard_lo: 170.0, f_soft: 310.0, f_soft_lo: 280.0, f_soft_hi: 340.0,
      f_self: 0.0, f_hat: 490.0, f_hat_lo: 450.0, f_hat_hi: 520.0,
      eihc: 96.0, rho_obs: 0.0774, q_score: 0.82, n_frac: 0.1458,
      rho_convention: "windowed", cold_start_tier: "full", confidence_marker: "reliable",
      reason_codes: [ { "code" => "HARD_NAMED_FRACTION", "params" => { "n" => 14, "pct" => 14.6 } } ]
    }.merge(attrs))
  end

  it "states what was shown, what came off it and what is left" do
    result = described_class.call(snapshot, channel: channel)

    expect(result[:shown]).to eq(1_240)
    expect(result[:real]).to eq(value: 750.0, lo: 620.0, hi: 880.0)
    expect(result[:arms].map { |a| a[:kind] }).to eq(%w[named deficit])
    expect(result[:arms].find { |a| a[:kind] == "named" }).to include(amount: 180.0, accounts: 14, share_of_chat_pct: 14.6)
    expect(result[:arms].find { |a| a[:kind] == "deficit" }[:amount]).to eq(310.0)
  end

  # The engine does not stack the arms into a waterfall: under the co-windowed convention the
  # named and silent arms ADD (disjoint populations) while the self-history arm competes by max.
  describe "fusion rule" do
    it "names the additive rule and both contributing arms under the windowed convention" do
      result = described_class.call(snapshot, channel: channel)

      expect(result[:fusion]).to include(mode: "sum", total: 490.0, lo: 450.0, hi: 520.0)
      expect(result[:fusion][:applied]).to contain_exactly("named", "deficit")
      expect(result[:arms].map { |a| a[:applied] }).to all(be(true))
    end

    it "marks only the largest arm as applied under the cumulative convention" do
      result = described_class.call(snapshot(rho_convention: "cumulative"), channel: channel)

      expect(result[:fusion][:mode]).to eq("max")
      expect(result[:fusion][:applied]).to eq([ "deficit" ]) # 310 beats 180
      expect(result[:arms].find { |a| a[:kind] == "named" }[:applied]).to be(false)
    end

    it "lets the self-history arm take the total when it exceeds the others" do
      result = described_class.call(snapshot(f_self: 900.0), channel: channel)

      expect(result[:fusion][:applied]).to eq([ "self_history" ])
      expect(result[:arms].find { |a| a[:kind] == "self_history" }[:amount]).to eq(900.0)
    end
  end

  describe "the peer baseline" do
    it "quotes the cell the engine used and translates it into one-in-N" do
      CalibrationCellBaseline.create!(category: "Just Chatting", v_bucket: "1k-5k", chat_mode: "open",
                                      language: "ru", rho_star: 0.24, rho_lo: 0.2, rho_hi: 0.3,
                                      calibrated: true)

      deficit = described_class.call(snapshot, channel: channel)[:arms].find { |a| a[:kind] == "deficit" }

      expect(deficit[:observed]).to eq(share: 0.0774, one_in: 12.9)
      expect(deficit[:expected]).to eq(share: 0.24, one_in: 4.2, calibrated: true)
    end

    it "says the baseline is not calibrated rather than implying a measurement" do
      CalibrationCellBaseline.create!(category: "default", v_bucket: "1k-5k", chat_mode: "open",
                                      language: "ru", rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05,
                                      calibrated: false)

      deficit = described_class.call(snapshot, channel: channel)[:arms].find { |a| a[:kind] == "deficit" }

      expect(deficit[:expected][:calibrated]).to be(false)
    end

    it "omits the expected share entirely when no cell resolves" do
      deficit = described_class.call(snapshot, channel: channel)[:arms].find { |a| a[:kind] == "deficit" }

      expect(deficit).not_to have_key(:expected)
    end
  end

  it "reports the chat measurements the subtraction rests on" do
    result = described_class.call(snapshot, channel: channel)

    expect(result[:chat]).to include(writers_effective: 96, quality: 0.82, convention: "windowed")
  end

  it "explains how wide the answer is, as a share of the shown online" do
    result = described_class.call(snapshot, channel: channel)

    expect(result[:confidence]).to include(marker: "reliable", cold_start_tier: "full")
    expect(result[:confidence][:interval_pct]).to eq(21.0) # (880 - 620) / 1240
  end

  it "omits an arm that measured nothing" do
    result = described_class.call(snapshot(f_soft: 0.0, f_soft_lo: 0.0, f_soft_hi: 0.0, rho_obs: nil), channel: channel)

    expect(result[:arms].map { |a| a[:kind] }).to eq([ "named" ])
  end

  it "returns nothing when there is no online to explain" do
    expect(described_class.call(snapshot(ccv: 0), channel: channel)).to be_nil
    expect(described_class.call(nil, channel: channel)).to be_nil
  end
end
