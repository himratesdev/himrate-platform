# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Aggregates::ViewRollupSource do
  let(:user) { create(:user) }
  let(:source) { described_class.new(user.id, Date.current - 30, Date.current) }

  def rollup(channel:, date: Date.current, seconds: 600, hours: { "20" => 600 }, devices: { "desktop" => 600 }, **extra)
    create(:pva_view_rollup, user: user, twitch_channel_id: channel, date: date, total_seconds: seconds,
      hour_histogram: hours, device_seconds: devices, first_seen_at: Time.current, last_seen_at: Time.current, **extra)
  end

  it "sums total seconds in the window" do
    rollup(channel: "1", seconds: 600)
    rollup(channel: "2", seconds: 300)
    expect(source.total_seconds).to eq(900)
  end

  it "merges device_seconds jsonb across rows" do
    rollup(channel: "1", devices: { "desktop" => 600 })
    rollup(channel: "2", devices: { "desktop" => 100, "mobile" => 200 })
    expect(source.device_seconds).to eq("desktop" => 700, "mobile" => 200)
  end

  it "builds a 7x24 heatmap matrix from hour_histogram bucketed by weekday" do
    rollup(channel: "1", date: Date.new(2026, 5, 20), hours: { "20" => 600 }) # Wed → wday 3
    matrix = source_for(Date.new(2026, 5, 1), Date.new(2026, 5, 31)).heatmap
    expect(matrix.length).to eq(7)
    expect(matrix[3][20]).to eq(600)
  end

  it "finds channels first seen within the discovery window (whole history)" do
    rollup(channel: "new", date: Date.current).update!(first_seen_at: 2.days.ago)
    rollup(channel: "old", date: Date.current).update!(first_seen_at: 60.days.ago)
    discovered = source.newly_discovered(7).map { |d| d[:twitch_channel_id] }
    expect(discovered).to contain_exactly("new")
  end

  def source_for(from, to)
    described_class.new(user.id, from, to)
  end
end
