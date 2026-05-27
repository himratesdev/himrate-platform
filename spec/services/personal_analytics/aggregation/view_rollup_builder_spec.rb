# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Aggregation::ViewRollupBuilder do
  let(:user) { create(:user) }
  let(:date) { Date.new(2026, 5, 20) }

  def raw(channel:, game:, hour:, seconds:, device: "desktop")
    create(:pva_view_event, user: user, twitch_channel_id: channel, game_id: game,
      started_at: Time.utc(2026, 5, 20, hour, 0, 0), seconds: seconds, device: device,
      source_event_hash: SecureRandom.hex(32))
  end

  it "builds a daily rollup grouped by channel+game with sums, histogram and devices" do
    raw(channel: "555", game: "g1", hour: 20, seconds: 600)
    raw(channel: "555", game: "g1", hour: 21, seconds: 300, device: "mobile")
    raw(channel: "555", game: "g2", hour: 20, seconds: 120)

    described_class.call(user.id, date)

    g1 = PvaViewRollup.find_by(user_id: user.id, twitch_channel_id: "555", game_id: "g1")
    expect(g1.total_seconds).to eq(900)
    expect(g1.session_count).to eq(2)
    expect(g1.hour_histogram).to eq("20" => 600, "21" => 300)
    expect(g1.device_seconds).to eq("desktop" => 600, "mobile" => 300)
    expect(PvaViewRollup.where(user_id: user.id).count).to eq(2) # g1 + g2 distinct
  end

  it "is idempotent — recompute replaces the bucket without duplicates" do
    raw(channel: "555", game: "g1", hour: 20, seconds: 600)

    described_class.call(user.id, date)
    described_class.call(user.id, date)

    expect(PvaViewRollup.where(user_id: user.id).count).to eq(1)
    expect(PvaViewRollup.find_by(user_id: user.id).total_seconds).to eq(600)
  end

  it "no-ops when there are no raw events for the date" do
    expect { described_class.call(user.id, date) }.not_to change(PvaViewRollup, :count)
  end
end
