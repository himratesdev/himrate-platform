# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::OverviewService do
  let(:user) { create(:user) }

  def rollup(channel:, login: nil, game: "509658", seconds: 600, hours: { "20" => 600 }, devices: { "desktop" => 600 })
    create(:pva_view_rollup, user: user, twitch_channel_id: channel, twitch_login: login, game_id: game,
      date: Date.current, total_seconds: seconds, session_count: 1, hour_histogram: hours, device_seconds: devices,
      first_seen_at: Time.current, last_seen_at: Time.current)
  end

  it "returns a cold-start payload when there is no data" do
    result = described_class.new(user: user, window: "30d").call

    expect(result[:data][:hero]).to be_nil
    expect(result[:data][:top_streamers]).to eq([])
    expect(result[:meta][:cold_start]).to be(true)
  end

  it "builds hero / top_streamers / categories / heatmap from rollups" do
    rollup(channel: "555", login: "xqc", seconds: 600, hours: { "20" => 600 }, devices: { "desktop" => 600 })
    rollup(channel: "777", login: "shroud", seconds: 300, hours: { "21" => 300 }, devices: { "desktop" => 300 })

    data = described_class.new(user: user, window: "30d").call[:data]

    expect(data[:hero][:seconds]).to eq(900)
    expect(data[:hero][:devices]).to eq([ { name: "desktop", seconds: 900 } ])
    expect(data[:top_streamers].map { |s| s[:login] }).to eq(%w[xqc shroud]) # desc by seconds
    expect(data[:categories].first[:pct]).to eq(100.0)
    expect(data[:heatmap][:matrix].length).to eq(7)
  end

  # Legacy v1 basis (trust_index_score). ti_v2_engine is in ALL_FLAGS → stance explicit; the v2
  # basis (authenticity, what PVA surfaces in production) is the example right below.
  it "enriches top_streamers with channel display_name + ti_score for tracked channels" do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(false)

    channel = create(:channel, twitch_id: "555", login: "xqc", display_name: "xQc")
    create(:trust_index_history, channel: channel, trust_index_score: 78.5, calculated_at: 1.hour.ago)
    rollup(channel: "555", login: "xqc")

    streamer = described_class.new(user: user, window: "30d").call[:data][:top_streamers].first

    expect(streamer[:display_name]).to eq("xQc")
    expect(streamer[:ti_score]).to eq(78.5)
  end

  it "enriches top_streamers from the v2 authenticity column under ti_v2_engine" do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)

    channel = create(:channel, twitch_id: "555", login: "xqc", display_name: "xQc")
    TrustIndexHistory.create!(channel: channel, engine_version: "v2", authenticity: 91.5,
                              cold_start_tier: "full", calculated_at: 1.hour.ago)
    # A stale v1 row must not win the enrichment — cross-engine mixing was the cutover bug class.
    create(:trust_index_history, channel: channel, trust_index_score: 10.0, calculated_at: 2.hours.ago)
    rollup(channel: "555", login: "xqc")

    streamer = described_class.new(user: user, window: "30d").call[:data][:top_streamers].first

    expect(streamer[:display_name]).to eq("xQc")
    # Contract (PR3b): the v2 value ships under `authenticity`; `ti_score` stays nil for the
    # current PVA frontend instead of carrying a cross-engine number under a retired name.
    expect(streamer[:authenticity]).to eq(91.5)
    expect(streamer[:ti_score]).to be_nil
  end

  it "raises InvalidWindow for an unknown window" do
    expect { described_class.new(user: user, window: "bogus") }.to raise_error(described_class::InvalidWindow)
  end
end
