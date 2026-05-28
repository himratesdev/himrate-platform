# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Enrollment::ExtensionSubsPayloadHandler do
  let(:user) { create(:user) }

  before do
    PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
  end

  describe ".call" do
    it "rejects invalid source" do
      expect {
        described_class.call(user_id: user.id, payload: { "source" => 99, "subscriptions" => [] })
      }.to raise_error(ArgumentError)
    end

    it "upserts ChannelTenure rows + creates Channel stubs" do
      payload = {
        "source" => 5,
        "subscriptions" => [
          { "channel_twitch_id" => "12345", "channel_login" => "shroud",
            "channel_display_name" => "shroud", "tier" => "1000",
            "cumulative_months" => 21, "anniversary_at" => "2024-12-15" }
        ]
      }

      result = described_class.call(user_id: user.id, payload: payload)
      expect(result.rows_affected).to eq(1)

      tenure = ChannelTenure.find_by(user_id: user.id)
      expect(tenure.months).to eq(21)
      expect(tenure.sub_tier).to eq(1)
      expect(tenure.twitch_login).to eq("shroud")
    end

    it "parses tier values 1000/2000/3000/Prime" do
      handler = described_class.new(user.id, {})
      expect(handler.send(:parse_tier, "1000")).to eq(1)
      expect(handler.send(:parse_tier, "2000")).to eq(2)
      expect(handler.send(:parse_tier, "3000")).to eq(3)
      expect(handler.send(:parse_tier, "Prime")).to eq(1)
      expect(handler.send(:parse_tier, "unknown")).to be_nil
    end

    it "skips entries без channel_twitch_id" do
      payload = {
        "source" => 5,
        "subscriptions" => [ { "channel_login" => "noid", "tier" => "1000", "cumulative_months" => 5 } ]
      }
      result = described_class.call(user_id: user.id, payload: payload)
      expect(result.rows_affected).to eq(0)
    end
  end
end
