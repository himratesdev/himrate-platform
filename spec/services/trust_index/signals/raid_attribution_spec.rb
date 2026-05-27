# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::RaidAttribution do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "raid_attribution", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.06 }
  end

  it "returns 0.0 with confidence 1.0 when no raids (clean stream)" do
    result = signal.calculate(raids: [])
    expect(result.value).to eq(0.0)
    expect(result.confidence).to eq(1.0)
  end

  # TASK-251.B core: getting raided is NOT itself evidence of bots. An organic / non-significant
  # raid (is_bot_raid=false) must contribute 0.0 — it must NOT lower the streamer's TI.
  it "returns 0.0 for organic / non-significant raids (no TI penalty for being raided)" do
    raids = [
      { timestamp: 5.minutes.ago, is_bot_raid: false, raid_viewers_count: 500, bot_score: nil },
      { timestamp: 3.minutes.ago, is_bot_raid: false, raid_viewers_count: 30, bot_score: 0.0 }
    ]
    result = signal.calculate(raids: raids)
    expect(result.value).to eq(0.0)
    expect(result.confidence).to eq(1.0)
    expect(result.metadata[:raids]).to eq(2)
    expect(result.metadata[:bot_raids]).to eq(0)
  end

  it "contributes the calibrated bot_score of a confirmed bot-raid" do
    raids = [ { timestamp: 5.minutes.ago, is_bot_raid: true, raid_viewers_count: 500, bot_score: 0.8 } ]
    result = signal.calculate(raids: raids)
    expect(result.value).to eq(0.8)
    expect(result.confidence).to eq(0.7) # probabilistic
    expect(result.metadata[:bot_raids]).to eq(1)
  end

  it "sums confirmed bot-raids and ignores organic ones in the same stream" do
    raids = [
      { timestamp: 9.minutes.ago, is_bot_raid: true,  raid_viewers_count: 200, bot_score: 0.5 },
      { timestamp: 6.minutes.ago, is_bot_raid: false, raid_viewers_count: 40,  bot_score: 0.0 },
      { timestamp: 3.minutes.ago, is_bot_raid: true,  raid_viewers_count: 300, bot_score: 0.25 }
    ]
    result = signal.calculate(raids: raids)
    expect(result.value).to be_within(0.0001).of(0.75) # 0.5 + 0.25, organic ignored
    expect(result.metadata[:raids]).to eq(3)
    expect(result.metadata[:bot_raids]).to eq(2)
  end

  it "clamps the summed bot_score to 1.0" do
    raids = [
      { timestamp: 8.minutes.ago, is_bot_raid: true, raid_viewers_count: 500, bot_score: 0.8 },
      { timestamp: 4.minutes.ago, is_bot_raid: true, raid_viewers_count: 500, bot_score: 0.6 }
    ]
    expect(signal.calculate(raids: raids).value).to eq(1.0)
  end

  # Integration: worker writes RaidAttribution → ContextBuilder.fetch_raids → signal #9.
  # Proves the real consumer path reads is_bot_raid/bot_score correctly and that an organically
  # raided stream is NOT penalised (the regression the signal rewrite fixes).
  describe "integration via ContextBuilder (TASK-251.B)" do
    let(:channel) { create(:channel) }
    let(:stream) { create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil) }

    it "does not penalise a stream that only received an organic raid" do
      create(:raid_attribution, stream: stream, timestamp: 10.minutes.ago,
                                is_bot_raid: false, bot_score: nil, raid_viewers_count: 120)
      ctx = TrustIndex::ContextBuilder.build(stream)
      result = signal.calculate(ctx)
      expect(result.value).to eq(0.0)
    end

    it "reflects a confirmed bot-raid's calibrated score through the real context" do
      create(:raid_attribution, stream: stream, timestamp: 10.minutes.ago,
                                is_bot_raid: true, bot_score: 0.75, raid_viewers_count: 400)
      ctx = TrustIndex::ContextBuilder.build(stream)
      result = signal.calculate(ctx)
      expect(result.value).to eq(0.75)
      expect(result.metadata[:bot_raids]).to eq(1)
    end
  end
end
