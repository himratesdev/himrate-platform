# frozen_string_literal: true

require "rails_helper"

module ReasonCodeBuilderSpecDoubles
  Band = Data.define(:row, :sub)
  Ctx = Data.define(:c_hard, :c_self, :c_inflation, :named_count, :named_pct, :self_history_stable,
                    :chatter_quality_high, :cold_start_tier, :stream_count,
                    :raid_window_suppressed_i, :unattributed_surge, :thin_sample)
end

RSpec.describe TrustIndex::V2::ReasonCodeBuilder do
  def band(row, sub = nil)
    ReasonCodeBuilderSpecDoubles::Band.new(row: row, sub: sub)
  end

  def ctx(**over)
    base = { c_hard: false, c_self: false, c_inflation: false, named_count: 0, named_pct: 0.0,
             self_history_stable: false, chatter_quality_high: false, cold_start_tier: "full",
             stream_count: 20, raid_window_suppressed_i: false, unattributed_surge: false, thin_sample: false }
    ReasonCodeBuilderSpecDoubles::Ctx.new(**base.merge(over))
  end

  def codes(band_obj, **over)
    described_class.call(band: band_obj, ctx: ctx(**over)).map(&:code)
  end

  it "RED/YELLOW → HARD_NAMED_FRACTION with N/pct params when C_hard" do
    result = described_class.call(band: band(1), ctx: ctx(c_hard: true, named_count: 290, named_pct: 58.0))
    hnf = result.find { |c| c.code == "HARD_NAMED_FRACTION" }
    expect(hnf.params).to eq({ n: 290, pct: 58.0 })
  end

  # TI v2.1 — the CCV-shape corroborator surfaces a per-STREAM (never per-person) reason code.
  it "RED/YELLOW → INFLATION_EVENT_CORROBORATION when C_inflation corroborates the soft deficit" do
    expect(codes(band(2), c_inflation: true)).to include("INFLATION_EVENT_CORROBORATION")
  end

  it "suppresses INFLATION_EVENT_CORROBORATION when C_hard already named a fraction (no redundant code)" do
    result = codes(band(1), c_hard: true, c_inflation: true)
    expect(result).to include("HARD_NAMED_FRACTION")
    expect(result).not_to include("INFLATION_EVENT_CORROBORATION")
  end

  it "RED/YELLOW → SELF_HISTORY_INFLATION_EVENT when C_self" do
    expect(codes(band(2), c_self: true)).to include("SELF_HISTORY_INFLATION_EVENT")
  end

  it "soft deficit alone (row 6a) → non-accusatory ENGAGEMENT_DEFICIT_UNCORROBORATED, no HARD/SELF" do
    result = codes(band(6, "6a"))
    expect(result).to eq([ "ENGAGEMENT_DEFICIT_UNCORROBORATED" ])
  end

  it "row 6b (correlated chatters) → CHATTER_QUALITY_LOW" do
    expect(codes(band(6, "6b"))).to eq([ "CHATTER_QUALITY_LOW" ])
  end

  it "GREEN row 3 → stable + quality positives" do
    expect(codes(band(3), self_history_stable: true, chatter_quality_high: true))
      .to contain_exactly("SELF_HISTORY_STABLE_CLEAN", "CHATTER_QUALITY_HIGH")
  end

  it "GREEN row 4 basic tier → PROVISIONAL_BASIC with stream count" do
    result = described_class.call(band: band(4), ctx: ctx(cold_start_tier: "basic", stream_count: 5))
    pb = result.find { |c| c.code == "PROVISIONAL_BASIC" }
    expect(pb.params).to eq({ n: 5 })
  end

  it "GREY row 5 → COLD_START_INSUFFICIENT with stream count" do
    expect(codes(band(5), cold_start_tier: "insufficient", stream_count: 2)).to eq([ "COLD_START_INSUFFICIENT" ])
  end

  it "cross-cutting suppression/interval codes attach on any row" do
    expect(codes(band(6, "6a"), raid_window_suppressed_i: true, unattributed_surge: true, thin_sample: true))
      .to include("RAID_HOST_EMBED_WINDOW", "UNATTRIBUTED_SURGE", "WIDE_INTERVAL_THIN_SAMPLE")
  end
end
