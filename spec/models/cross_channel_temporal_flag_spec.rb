# frozen_string_literal: true

require "rails_helper"

RSpec.describe CrossChannelTemporalFlag do
  def build_flag(**overrides)
    described_class.new({
      username: "bot1", event_count: 9, max_concurrent_channels: 3,
      bot_flag_tier: "confirmed", bot_type: "spam", window_seconds: 5, refreshed_at: Time.current
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with the full attribute set" do
      expect(build_flag).to be_valid
    end

    it "rejects an unknown tier" do
      expect(build_flag(bot_flag_tier: "bogus")).not_to be_valid
    end

    it "rejects an unknown bot_type" do
      expect(build_flag(bot_type: "bogus")).not_to be_valid
    end
  end

  describe ".bulk_lookup" do
    before { build_flag(username: "bot1").save! }

    it "returns symbol-keyed metadata only for present usernames" do
      result = described_class.bulk_lookup(%w[bot1 absent])

      expect(result.keys).to eq([ "bot1" ])
      expect(result["bot1"]).to include(
        bot_flag_tier: "confirmed", bot_type: "spam", event_count: 9, max_concurrent_channels: 3
      )
    end

    it "returns {} for empty or nil input" do
      expect(described_class.bulk_lookup([])).to eq({})
      expect(described_class.bulk_lookup(nil)).to eq({})
    end
  end
end
