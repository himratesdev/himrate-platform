# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Engine do
  let(:engine) { described_class.new }
  let(:channel) { Channel.create!(twitch_id: "ti_ch", login: "ti_channel", display_name: "TI") }
  let(:stream) { Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago) }

  # Create 10 completed streams so ColdStartGuard returns confidence=1.0 (no Bayesian influence)
  before do
    10.times { Stream.create!(channel: channel, started_at: 3.hours.ago, ended_at: 2.hours.ago) }
  end

  before do
    # Seed configs
    TiSignal::SIGNAL_TYPES.each do |type|
      SignalConfiguration.find_or_create_by!(
        signal_type: type, category: "default", param_name: "weight_in_ti"
      ) { |c| c.param_value = 1.0 / TiSignal::SIGNAL_TYPES.size }

      SignalConfiguration.find_or_create_by!(
        signal_type: type, category: "default", param_name: "alert_threshold"
      ) { |c| c.param_value = 0.5 }
    end

    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "population_mean"
    ) { |c| c.param_value = 65.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "incident_threshold"
    ) { |c| c.param_value = 40.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "rehabilitation_streams"
    ) { |c| c.param_value = 15.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "rehabilitation_bonus_max"
    ) { |c| c.param_value = 15.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "trusted_min"
    ) { |c| c.param_value = 80.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "needs_review_min"
    ) { |c| c.param_value = 50.0 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "suspicious_min"
    ) { |c| c.param_value = 25.0 }
  end

  def make_result(value:, confidence: 1.0)
    TrustIndex::Signals::BaseSignal::Result.new(value: value, confidence: confidence, metadata: {})
  end

  def all_signals(value:, confidence: 1.0)
    TiSignal::SIGNAL_TYPES.each_with_object({}) do |type, h|
      h[type] = make_result(value: value, confidence: confidence)
    end
  end

  it "computes TI=100 when all signals are 0 (no bots)" do
    result = engine.compute(signal_results: all_signals(value: 0.0), stream: stream, ccv: 1000)
    expect(result.ti_score).to eq(100)
    expect(result.classification).to eq("trusted")
  end

  it "computes TI=0 when all signals are 1.0 (all bots)" do
    result = engine.compute(signal_results: all_signals(value: 1.0), stream: stream, ccv: 1000)
    expect(result.ti_score).to eq(0)
    expect(result.classification).to eq("fraudulent")
  end

  it "computes weighted average for mixed signals" do
    signals = all_signals(value: 0.3)
    result = engine.compute(signal_results: signals, stream: stream, ccv: 1000)
    expect(result.ti_score).to be_between(60, 80)
  end

  it "skips nil signals and renormalizes weights" do
    signals = all_signals(value: 0.0)
    signals["auth_ratio"] = make_result(value: nil)
    signals["chat_behavior"] = make_result(value: nil)
    signals["raid_attribution"] = make_result(value: nil)
    result = engine.compute(signal_results: signals, stream: stream, ccv: 1000)
    expect(result.ti_score).to eq(100) # remaining 8 signals all 0
  end

  it "returns population_mean (65) when all signals nil" do
    signals = all_signals(value: nil)
    result = engine.compute(signal_results: signals, stream: stream, ccv: 1000)
    expect(result.ti_score).to eq(65)
  end

  it "computes ERV correctly" do
    result = engine.compute(signal_results: all_signals(value: 0.28), stream: stream, ccv: 5000)
    expect(result.erv[:erv_count]).to be_between(3000, 4500)
    expect(result.erv[:erv_percent]).to be_between(60.0, 90.0)
  end

  it "assigns ERV labels correctly" do
    # High TI → green
    result_green = engine.compute(signal_results: all_signals(value: 0.1), stream: stream, ccv: 1000)
    expect(result_green.erv[:label_color]).to eq("green")

    # Medium TI → yellow
    result_yellow = engine.compute(signal_results: all_signals(value: 0.4), stream: stream, ccv: 1000)
    expect(result_yellow.erv[:label_color]).to eq("yellow")
  end

  it "persists TrustIndexHistory and ErvEstimate" do
    expect {
      engine.compute(signal_results: all_signals(value: 0.2), stream: stream, ccv: 1000)
    }.to change(TrustIndexHistory, :count).by(1).and change(ErvEstimate, :count).by(1)

    tih = TrustIndexHistory.last
    expect(tih.classification).to be_present
    expect(tih.cold_start_status).to be_present
  end

  it "applies Bayesian shrinkage for low confidence" do
    channel2 = Channel.create!(twitch_id: "bay_ch", login: "bay_channel", display_name: "Bayesian")
    stream2 = Stream.create!(channel: channel2, started_at: 2.hours.ago, ended_at: 1.hour.ago)
    # Only 5 completed streams → confidence = 0.5
    4.times { Stream.create!(channel: channel2, started_at: 3.hours.ago, ended_at: 2.hours.ago) }
    result = engine.compute(signal_results: all_signals(value: 0.0), stream: stream2, ccv: 1000)
    # TI should be between 65 (pop mean) and 100 (calculated) due to shrinkage
    expect(result.ti_score).to be_between(65, 100)
    expect(result.ti_score).to be < 100
  end
end
