# frozen_string_literal: true

require "rails_helper"

module InflationEventSpecDoubles
  Signals = Data.define(:rho_dropped_vs_baseline, :v_above_own_trend, :raid_window,
                        :chat_arrival_below_floor, :no_follower_sub_bump,
                        :variance_below_floor_or_plateau, :unattributed_surge, :cold_start_tier)
end

RSpec.describe TrustIndex::V2::InflationEvent do
  def signals(**over)
    base = { rho_dropped_vs_baseline: true, v_above_own_trend: true, raid_window: false,
             chat_arrival_below_floor: true, no_follower_sub_bump: true,
             variance_below_floor_or_plateau: true, unattributed_surge: false, cold_start_tier: "full" }
    InflationEventSpecDoubles::Signals.new(**base.merge(over))
  end

  it "fires I=1 when all six conditions hold (convert-from-honest inflation)" do
    expect(described_class.call(signals).i_event).to be(true)
  end

  it "does NOT fire when any single condition is absent" do
    expect(described_class.call(signals(v_above_own_trend: false)).i_event).to be(false)
    expect(described_class.call(signals(no_follower_sub_bump: false)).i_event).to be(false)
    expect(described_class.call(signals(chat_arrival_below_floor: false)).i_event).to be(false)
  end

  it "suppresses (I=0) during a raid/host/viral window even if the rest hold" do
    expect(described_class.call(signals(raid_window: true)).i_event).to be(false)
  end

  it "fail-safe I=0 on cold-start insufficient (no self-history to compare)" do
    r = described_class.call(signals(cold_start_tier: "insufficient"))
    expect(r.i_event).to be(false)
  end

  it "an unattributed real surge suppresses I and is surfaced (→ widen interval, never accuse)" do
    r = described_class.call(signals(unattributed_surge: true))
    expect(r.i_event).to be(false)
    expect(r.unattributed_surge).to be(true)
  end
end
