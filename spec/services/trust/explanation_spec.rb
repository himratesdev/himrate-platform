# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trust::Explanation do
  let(:channel) { create(:channel) }
  # Mirrors production: streams carry the Twitch game NAME and an uppercase language, while the
  # calibration corpus is keyed by the normalised category slug. Getting that wrong is exactly how
  # the baseline silently disappears from the card.
  let!(:stream) { create(:stream, channel: channel, game_name: "Just Chatting", language: "RU") }

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
      CalibrationCellBaseline.create!(category: "just_chatting", v_bucket: "1k-5k", chat_mode: "open",
                                      language: "RU", rho_star: 0.24, rho_lo: 0.2, rho_hi: 0.3,
                                      calibrated: true)

      deficit = described_class.call(snapshot, channel: channel)[:arms].find { |a| a[:kind] == "deficit" }

      expect(deficit[:observed]).to eq(share: 0.0774, one_in: 12.9)
      expect(deficit[:expected]).to eq(share: 0.24, one_in: 4.2, calibrated: true)
    end

    it "says the baseline is not calibrated rather than implying a measurement" do
      CalibrationCellBaseline.create!(category: "default", v_bucket: "1k-5k", chat_mode: "open",
                                      language: "RU", rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05,
                                      calibrated: false)

      deficit = described_class.call(snapshot, channel: channel)[:arms].find { |a| a[:kind] == "deficit" }

      expect(deficit[:expected][:calibrated]).to be(false)
    end

    it "ignores a cell keyed by the raw Twitch game name — the corpus uses the category slug" do
      CalibrationCellBaseline.create!(category: "Just Chatting", v_bucket: "1k-5k", chat_mode: "open",
                                      language: "RU", rho_star: 0.24, rho_lo: 0.2, rho_hi: 0.3,
                                      calibrated: true)

      deficit = described_class.call(snapshot, channel: channel)[:arms].find { |a| a[:kind] == "deficit" }

      expect(deficit).not_to have_key(:expected)
    end

    it "omits the expected share entirely when no cell resolves" do
      deficit = described_class.call(snapshot, channel: channel)[:arms].find { |a| a[:kind] == "deficit" }

      expect(deficit).not_to have_key(:expected)
    end
  end

  # DETECTION-AUDIT 2026-09-19 (CR iter-2 MF-2, superseding iter-1 SF-3). `applied` is ARITHMETIC:
  # ERV = V − F̂ subtracts the named accounts whether or not the verdict accused on them, so greying
  # the row would put a sum that does not add up on a card open to guests (~15k rows/day carry
  # f_hard > 0 with no HARD_NAMED_FRACTION). The accusation side is a SEPARATE flag: `set_aside`,
  # only where the row can prove the chat was too small for a fraction to mean anything.
  describe "named arm below the named-fraction roster floor" do
    # Live shape: one spam account in a 2-chatter, CCV-3 channel. No HARD_NAMED_FRACTION (the floor
    # held the accusation back) → AMBER; the arm still measured something and was still subtracted.
    def micro_row(**over)
      snapshot(ccv: 3, erv: 2, erv_lo: 2, erv_hi: 2, f_hard: 0.98, f_hard_lo: 0.44, f_soft: 0.0,
               f_soft_lo: 0.0, f_soft_hi: 0.0, f_hat: 0.98, f_hat_lo: 0.98, f_hat_hi: 0.98, n_frac: 0.4378,
               n_chat_eff: 2, band_color: "amber", reason_codes: [], **over)
    end

    it "keeps the arm applied — it formed the total — and marks it set aside instead" do
      %w[windowed cumulative].each do |convention|
        result = described_class.call(micro_row(rho_convention: convention), channel: channel)
        named = result[:arms].find { |a| a[:kind] == "named" }

        expect(named).to include(amount: 1.0, applied: true, set_aside: true)
        expect(result[:fusion][:applied]).to eq([ "named" ])
      end
    end

    it "carries the reason in words, resolved in the request locale" do
      named = I18n.with_locale(:ru) do
        described_class.call(micro_row(n_chat_eff: 3), channel: channel)[:arms].find { |a| a[:kind] == "named" }
      end

      expect(named[:set_aside_note]).to eq(I18n.t("explanation.named_set_aside", n: 3, locale: :ru))
      expect(named[:set_aside_note]).to include("3")
    end

    it "sets the arm aside at any roster below the live floor, and never at or above it" do
      floor = Calibration::Registry.load.chard_frac_roster_min.to_i # 5 unless calibrated otherwise

      below = described_class.call(micro_row(n_chat_eff: floor - 1), channel: channel)
      at_floor = described_class.call(micro_row(n_chat_eff: floor), channel: channel)

      expect(below[:arms].find { |a| a[:kind] == "named" }[:set_aside]).to be(true)
      expect(at_floor[:arms].find { |a| a[:kind] == "named" }).not_to have_key(:set_aside)
    end

    it "never sets aside an arm the engine itself published as a reason" do
      coded = micro_row(reason_codes: [ { "code" => "HARD_NAMED_FRACTION", "params" => { "n" => 1, "pct" => 44.0 } } ])
      named = described_class.call(coded, channel: channel)[:arms].find { |a| a[:kind] == "named" }

      expect(named).to include(applied: true)
      expect(named).not_to have_key(:set_aside)
    end

    it "shows the roster next to the fraction, so 0.44 reads as «of 2 chatters»" do
      expect(described_class.call(micro_row, channel: channel)[:chat]).to include(named_fraction: 0.4378, roster: 2)
    end

    # The 15k-rows/day class the iter-1 rule broke: a green row that measured named accounts but
    # carries no code, on a roster far above the floor.
    it "a green row with no code, well above the floor, is applied and not set aside" do
      result = described_class.call(snapshot(n_chat_eff: 96, band_color: "green", reason_codes: []), channel: channel)
      named = result[:arms].find { |a| a[:kind] == "named" }

      expect(named).to include(amount: 180.0, applied: true)
      expect(named).not_to have_key(:set_aside)
      expect(named).not_to have_key(:set_aside_note)
      expect(result[:fusion][:applied]).to contain_exactly("named", "deficit")
    end

    it "control: at/above the floor WITH the reason code the arm is applied exactly as before" do
      result = described_class.call(snapshot(n_chat_eff: 96), channel: channel)

      expect(result[:arms].find { |a| a[:kind] == "named" }[:applied]).to be(true)
      expect(result[:fusion][:applied]).to contain_exactly("named", "deficit")
      expect(result[:chat][:roster]).to eq(96)
    end

    it "rows persisted before the column existed (n_chat_eff NULL) keep their payload — no roster key" do
      result = described_class.call(snapshot(n_chat_eff: nil), channel: channel)

      expect(result[:chat]).not_to have_key(:roster)
      expect(result[:chat]).to eq(writers_effective: 96, quality: 0.82, named_fraction: 0.1458, convention: "windowed")
    end

    # Same row, no code either — the pre-branch shape has to come back byte-for-byte, keys included.
    it "a NULL-roster row without the reason code carries no set-aside keys at all" do
      named = described_class.call(snapshot(n_chat_eff: nil, reason_codes: []), channel: channel)[:arms]
                             .find { |a| a[:kind] == "named" }

      expect(named).to eq(kind: "named", amount: 180.0, lo: 170.0, applied: true)
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
