# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::CrossChannelPresence do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "cross_channel_presence", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.08 }
  end

  it "returns value proportional to bots in 50+ channels" do
    counts = { "user1" => 60, "user2" => 55, "user3" => 5, "user4" => 3, "user5" => 1 }
    result = signal.calculate(cross_channel_counts: counts)
    expect(result.value).to be > 0.0
    expect(result.metadata[:bots_50plus]).to eq(2)
  end

  it "includes suspicious (30-50) at reduced weight" do
    counts = { "user1" => 35, "user2" => 5, "user3" => 3 }
    result = signal.calculate(cross_channel_counts: counts)
    expect(result.value).to be > 0.0
    expect(result.metadata[:suspicious_30plus]).to eq(1)
  end

  it "returns 0 when all chatters are normal" do
    counts = { "user1" => 5, "user2" => 3, "user3" => 1 }
    result = signal.calculate(cross_channel_counts: counts)
    expect(result.value).to eq(0.0)
  end

  it "returns nil for empty data" do
    result = signal.calculate(cross_channel_counts: {})
    expect(result.value).to be_nil
  end
end
