# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::TenureIngestWorker do
  let(:user) { create(:user) }

  def snapshot(overrides = {})
    { "channel_id" => "555", "login" => "xqc", "sub_tier" => 2, "months" => 18, "streak" => 12,
      "anniversary_at" => "2024-11-28", "observed_at" => Time.utc(2026, 5, 28, 20).iso8601 }.merge(overrides)
  end

  it "ingests a sub-tenure snapshot into channel_tenure (M8 writer)" do
    described_class.new.perform(user.id, [ snapshot ])

    tenure = ChannelTenure.find_by(user_id: user.id, twitch_channel_id: "555")
    expect(tenure.months).to eq(18)
    expect(tenure.sub_tier).to eq(2)
    expect(tenure.twitch_login).to eq("xqc")
  end

  it "is idempotent by replace — latest badge-info wins" do
    described_class.new.perform(user.id, [ snapshot(months: 18) ])
    described_class.new.perform(user.id, [ snapshot(months: 20) ])

    expect(ChannelTenure.where(user_id: user.id).count).to eq(1)
    expect(ChannelTenure.find_by(user_id: user.id).months).to eq(20)
  end

  it "drops invalid snapshots and clamps an out-of-range sub_tier to nil" do
    described_class.new.perform(user.id, [ snapshot(channel_id: "") ])
    expect(ChannelTenure.where(user_id: user.id)).to be_empty

    described_class.new.perform(user.id, [ snapshot(channel_id: "777", sub_tier: 9) ])
    expect(ChannelTenure.find_by(twitch_channel_id: "777").sub_tier).to be_nil
  end
end
