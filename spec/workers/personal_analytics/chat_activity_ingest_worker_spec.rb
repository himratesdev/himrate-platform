# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::ChatActivityIngestWorker do
  let(:user) { create(:user) }

  def snapshot(overrides = {})
    { "channel_id" => "555", "login" => "xqc", "date" => "2026-05-28", "message_count" => 25,
      "emote_counts" => { "Kappa" => 10 }, "first_seen_at" => Time.utc(2026, 5, 28, 20).iso8601,
      "last_seen_at" => Time.utc(2026, 5, 28, 21).iso8601 }.merge(overrides)
  end

  it "ingests a chat snapshot into pva_chat_activities" do
    described_class.new.perform(user.id, [ snapshot ])

    row = PvaChatActivity.find_by(user_id: user.id, twitch_channel_id: "555")
    expect(row.message_count).to eq(25)
    expect(row.emote_counts).to eq("Kappa" => 10)
  end

  it "is idempotent by replace — re-send same (channel,date) updates, no duplicates (latest wins)" do
    described_class.new.perform(user.id, [ snapshot(message_count: 25) ])
    described_class.new.perform(user.id, [ snapshot(message_count: 40) ])

    expect(PvaChatActivity.where(user_id: user.id).count).to eq(1)
    expect(PvaChatActivity.find_by(user_id: user.id).message_count).to eq(40)
  end

  it "clamps negative message_count to 0" do
    described_class.new.perform(user.id, [ snapshot(message_count: -5) ])

    expect(PvaChatActivity.find_by(user_id: user.id).message_count).to eq(0)
  end

  it "drops invalid snapshots (missing channel / unparseable date)" do
    described_class.new.perform(user.id, [ snapshot(channel_id: ""), snapshot(date: "not-a-date") ])

    expect(PvaChatActivity.where(user_id: user.id)).to be_empty
  end
end
