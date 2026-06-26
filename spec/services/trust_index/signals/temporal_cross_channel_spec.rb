# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::TemporalCrossChannel do
  let(:signal) { described_class.new }

  def ctx(total:, flagged:)
    { temporal_cross_channel_flags: { total_chatters: total, flagged: flagged } }
  end

  it "is insufficient when there is no temporal data" do
    expect(signal.calculate({}).value).to be_nil
    expect(signal.calculate(temporal_cross_channel_flags: {}).value).to be_nil
    expect(signal.calculate(ctx(total: 0, flagged: {})).value).to be_nil
  end

  it "weights spam tiers and divides by total chatters (not the flagged subset)" do
    flagged = {
      "a" => { bot_flag_tier: "confirmed", bot_type: "spam" },
      "b" => { bot_flag_tier: "yellow",    bot_type: "spam" }
    }
    result = signal.calculate(ctx(total: 100, flagged: flagged))

    expect(result.value).to be_within(0.0001).of((1.0 + 0.6) / 100)
    expect(result.metadata[:spam_flagged]).to eq(2)
    expect(result.metadata[:confirmed]).to eq(1)
  end

  it "excludes utility (allowlisted) bots from the fraud value (BR-10)" do
    flagged = {
      "nightbot" => { bot_flag_tier: "confirmed", bot_type: "utility" },
      "spammer"  => { bot_flag_tier: "confirmed", bot_type: "spam" }
    }
    result = signal.calculate(ctx(total: 50, flagged: flagged))

    expect(result.value).to be_within(0.0001).of(1.0 / 50) # only the spam one counts
    expect(result.metadata[:utility_excluded]).to eq(1)
  end

  it "treats watch tier as a zero-weight noise floor" do
    flagged = { "w" => { bot_flag_tier: "watch", bot_type: "spam" } }
    expect(signal.calculate(ctx(total: 10, flagged: flagged)).value).to eq(0.0)
  end

  it "scales confidence with the present-chatter sample size" do
    expect(signal.calculate(ctx(total: 25, flagged: {})).confidence).to eq(0.5)
    expect(signal.calculate(ctx(total: 100, flagged: {})).confidence).to eq(1.0)
  end
end
