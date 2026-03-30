# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::RehabilitationCurve do
  let(:channel) { Channel.create!(twitch_id: "rehab_ch", login: "rehab_channel", display_name: "Rehab") }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "incident_threshold"
    ) { |c| c.param_value = 40.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "population_mean"
    ) { |c| c.param_value = 65.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "rehabilitation_streams"
    ) { |c| c.param_value = 15.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "rehabilitation_bonus_max"
    ) { |c| c.param_value = 15.0 }
  end

  def create_incident(channel, ti_score: 20)
    stream = Stream.create!(channel: channel, started_at: 10.days.ago, ended_at: 10.days.ago + 2.hours)
    TrustIndexHistory.create!(
      channel: channel, stream: stream,
      trust_index_score: ti_score, calculated_at: 10.days.ago,
      confidence: 1.0, signal_breakdown: {}
    )
    stream
  end

  def create_clean_stream(channel, days_ago: 1, ti_score: 70)
    stream = Stream.create!(channel: channel, started_at: days_ago.days.ago, ended_at: days_ago.days.ago + 2.hours)
    TrustIndexHistory.create!(
      channel: channel, stream: stream,
      trust_index_score: ti_score, calculated_at: days_ago.days.ago,
      confidence: 1.0, signal_breakdown: {}
    )
  end

  it "returns no penalty when no incident" do
    result = described_class.apply(channel: channel, calculated_ti: 80.0)
    expect(result[:penalty]).to eq(0.0)
    expect(result[:adjusted_ti]).to eq(80.0)
  end

  it "applies full penalty at 0 clean streams" do
    create_incident(channel, ti_score: 20) # penalty = 65 - 20 = 45
    result = described_class.apply(channel: channel, calculated_ti: 80.0)
    expect(result[:penalty]).to eq(45.0)
    expect(result[:adjusted_ti]).to eq(35.0) # 80 - 45
  end

  it "reduces penalty with 5 clean streams (67%)" do
    create_incident(channel, ti_score: 20) # penalty = 45
    5.times { |i| create_clean_stream(channel, days_ago: 9 - i, ti_score: 70) }
    result = described_class.apply(channel: channel, calculated_ti: 80.0)
    expect(result[:penalty]).to be_between(28.0, 32.0) # ~45 * 0.67 = ~30
    expect(result[:clean_streams]).to eq(5)
  end

  it "removes penalty completely at 15 clean streams" do
    create_incident(channel, ti_score: 20)
    15.times { |i| create_clean_stream(channel, days_ago: 9 - i, ti_score: 70) }
    result = described_class.apply(channel: channel, calculated_ti: 80.0)
    expect(result[:penalty]).to eq(0.0)
    expect(result[:adjusted_ti]).to be >= 80.0
  end

  it "adds rehabilitation bonus during recovery" do
    create_incident(channel, ti_score: 20)
    5.times { |i| create_clean_stream(channel, days_ago: 9 - i, ti_score: 70) }
    result = described_class.apply(channel: channel, calculated_ti: 80.0)
    expect(result[:bonus]).to be > 0.0
    expect(result[:bonus]).to be <= 15.0
  end

  it "auto-exonerates bot-raid victims" do
    incident_stream = create_incident(channel, ti_score: 20)
    # Mark the incident stream as bot-raid target
    RaidAttribution.create!(
      stream: incident_stream, timestamp: 10.days.ago,
      is_bot_raid: true, raid_viewers_count: 500
    )
    result = described_class.apply(channel: channel, calculated_ti: 80.0)
    expect(result[:penalty]).to eq(0.0)
    expect(result[:auto_exonerated]).to be true
  end

  it "clamps adjusted_ti to 0-100" do
    create_incident(channel, ti_score: 5) # penalty = 60
    result = described_class.apply(channel: channel, calculated_ti: 30.0)
    expect(result[:adjusted_ti]).to be >= 0.0
  end
end
