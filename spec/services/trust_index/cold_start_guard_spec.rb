# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::ColdStartGuard do
  let(:channel) { Channel.create!(twitch_id: "cs_ch", login: "cs_channel", display_name: "CS") }

  def create_completed_streams(count)
    count.times { Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago) }
  end

  it "returns insufficient for 0-2 streams" do
    create_completed_streams(2)
    result = described_class.assess(channel)
    expect(result[:status]).to eq("insufficient")
    expect(result[:confidence]).to eq(0.2)
  end

  it "returns provisional_low for 3-6 streams" do
    create_completed_streams(5)
    result = described_class.assess(channel)
    expect(result[:status]).to eq("provisional_low")
    expect(result[:confidence]).to eq(0.5)
  end

  it "returns provisional for 7-9 streams" do
    create_completed_streams(8)
    result = described_class.assess(channel)
    expect(result[:status]).to eq("provisional")
    expect(result[:confidence]).to eq(0.8)
  end

  it "returns full for 10+ streams" do
    create_completed_streams(12)
    result = described_class.assess(channel)
    expect(result[:status]).to eq("full")
    expect(result[:confidence]).to eq(1.0)
  end

  it "returns deep for 30+ streams" do
    create_completed_streams(35)
    result = described_class.assess(channel)
    expect(result[:status]).to eq("deep")
    expect(result[:confidence]).to eq(1.0)
  end

  it "does not count active streams (no ended_at)" do
    Stream.create!(channel: channel, started_at: 1.hour.ago, ended_at: nil)
    create_completed_streams(2)
    result = described_class.assess(channel)
    expect(result[:stream_count]).to eq(2)
  end
end
