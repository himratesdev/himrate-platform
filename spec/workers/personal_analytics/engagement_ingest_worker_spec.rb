# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::EngagementIngestWorker do
  let(:user) { create(:user) }

  def event(overrides = {})
    { "client_event_id" => SecureRandom.uuid, "event_type" => "cheer", "channel_id" => "555",
      "login" => "xqc", "amount" => 100, "occurred_at" => Time.utc(2026, 5, 28, 20).iso8601,
      "anonymous" => false }.merge(overrides)
  end

  it "ingests discrete events into pva_engagement_events keyed by event_hash" do
    described_class.new.perform(user.id, [ event ])

    row = PvaEngagementEvent.find_by(user_id: user.id)
    expect(row.twitch_channel_id).to eq("555")
    expect(row.event_type).to eq("cheer")
    expect(row.amount).to eq(100)
    expect(row.source).to eq("client_capture")
  end

  it "is idempotent — same client_event_id twice → one row" do
    payload = event
    described_class.new.perform(user.id, [ payload ])
    described_class.new.perform(user.id, [ payload ])

    expect(PvaEngagementEvent.where(user_id: user.id).count).to eq(1)
  end

  it "enriches channel for tracked, falls back to payload login for untracked" do
    create(:channel, twitch_id: "555", login: "xqc")

    described_class.new.perform(user.id, [ event(channel_id: "555", login: "ignored"),
                                           event(channel_id: "999", login: "untrackedguy") ])

    expect(PvaEngagementEvent.find_by(twitch_channel_id: "555").twitch_login).to eq("xqc")
    untracked = PvaEngagementEvent.find_by(twitch_channel_id: "999")
    expect(untracked.channel_id).to be_nil
    expect(untracked.twitch_login).to eq("untrackedguy")
  end

  it "drops invalid events (bad type / missing channel)" do
    described_class.new.perform(user.id, [ event(event_type: "bogus"), event(channel_id: "") ])

    expect(PvaEngagementEvent.where(user_id: user.id)).to be_empty
  end
end
