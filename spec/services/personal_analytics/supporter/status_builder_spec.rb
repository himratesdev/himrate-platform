# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Supporter::StatusBuilder do
  let(:user) { create(:user) }

  it "computes the devoted tier from tenure + cheers + hype (ADR OQ-1 composite)" do
    create(:channel_tenure, user: user, twitch_channel_id: "555", months: 18)          # 18*2 = 36
    create(:pva_engagement_event, user: user, twitch_channel_id: "555", event_type: "cheer", amount: 500) # 500/100 = 5
    create(:pva_engagement_event, user: user, twitch_channel_id: "555", event_type: "hype_contribution", amount: nil) # 1*3 = 3

    described_class.call(user.id)

    status = PvaSupporterStatus.find_by(user_id: user.id, twitch_channel_id: "555")
    expect(status.composite_score).to eq(44.0)
    expect(status.tier).to eq("devoted") # >= 40
  end

  it "maps composite to the absolute ladder (loyal / regular / active — BR-006 categorical)" do
    create(:channel_tenure, user: user, twitch_channel_id: "loyalch", months: 11) # 22 → loyal
    create(:channel_tenure, user: user, twitch_channel_id: "regch", months: 4)    # 8  → regular
    create(:channel_tenure, user: user, twitch_channel_id: "actch", months: 1)    # 2  → active

    described_class.call(user.id)

    expect(PvaSupporterStatus.find_by(twitch_channel_id: "loyalch").tier).to eq("loyal")
    expect(PvaSupporterStatus.find_by(twitch_channel_id: "regch").tier).to eq("regular")
    expect(PvaSupporterStatus.find_by(twitch_channel_id: "actch").tier).to eq("active")
  end

  it "is idempotent — recompute updates the tier without duplicates" do
    create(:channel_tenure, user: user, twitch_channel_id: "555", months: 1)
    described_class.call(user.id)
    ChannelTenure.where(user_id: user.id, twitch_channel_id: "555").update_all(months: 20) # → 40 devoted

    described_class.call(user.id)

    expect(PvaSupporterStatus.where(user_id: user.id).count).to eq(1)
    expect(PvaSupporterStatus.find_by(user_id: user.id).tier).to eq("devoted")
  end

  it "no-ops when the user has no engagement or tenure" do
    expect { described_class.call(user.id) }.not_to change(PvaSupporterStatus, :count)
  end
end
