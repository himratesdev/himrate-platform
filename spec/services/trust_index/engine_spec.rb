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

  # Phase 4 J PR-F calibration fix per PO directive 2026-06-02 «для clean
  # signals TI=100 + label «Аудитория реальная»». High-confidence clean signals
  # must not be pulled down by cold-start Bayesian shrinkage; low-confidence
  # signals still benefit from the population-mean prior against sampling noise.
  it "skips Bayesian shrinkage for high-confidence clean signals on cold-start channel" do
    channel2 = Channel.create!(twitch_id: "cs_clean_ch", login: "cs_clean", display_name: "ColdStartClean")
    stream2 = Stream.create!(channel: channel2, started_at: 2.hours.ago, ended_at: 1.hour.ago)
    # Only 5 completed streams (4 here + stream2 finished) → cold_start confidence = 0.5
    4.times { Stream.create!(channel: channel2, started_at: 3.hours.ago, ended_at: 2.hours.ago) }
    result = engine.compute(signal_results: all_signals(value: 0.0, confidence: 1.0), stream: stream2, ccv: 1000)
    # signal_confidence = 1.0 → Bayesian skipped → ti_raw = 100 returned directly
    expect(result.ti_score).to eq(100)
    expect(result.classification).to eq("trusted")
    # cold_start still reports the channel's history depth — only the scoring math changes
    expect(result.cold_start[:status]).to eq("provisional_low")
    expect(result.cold_start[:confidence]).to eq(0.5)
  end

  it "applies Bayesian shrinkage when signal_confidence is low (noisy data)" do
    channel3 = Channel.create!(twitch_id: "cs_noisy_ch", login: "cs_noisy", display_name: "ColdStartNoisy")
    stream3 = Stream.create!(channel: channel3, started_at: 2.hours.ago, ended_at: 1.hour.ago)
    4.times { Stream.create!(channel: channel3, started_at: 3.hours.ago, ended_at: 2.hours.ago) }
    # Low per-signal confidence → avg signal_confidence < 0.95 → Bayesian engages
    result = engine.compute(signal_results: all_signals(value: 0.0, confidence: 0.5), stream: stream3, ccv: 1000)
    # ti_raw computation: each contribution = 0.0 × 0.5 × weight = 0 → bot_score=0 → ti_raw=100
    # signal_confidence avg = 0.5 → below 0.95 threshold → Bayesian path taken
    # cold_start[:confidence] = 0.5 → ti_bayesian = 0.5 × 100 + 0.5 × 65 = 82.5 → rounds to 83
    expect(result.ti_score).to be_between(65, 100)
    expect(result.ti_score).to be < 100
  end

  # PR-F regression spec: dirty-signal cold-start channels must NOT be pulled
  # UP toward population_mean=65. Pre-PR-F, ti_raw=30 (clear bot pattern) on a
  # cold-start channel was elevated to ~54 by Bayesian shrinkage — masking the
  # anomaly. Post-PR-F, high signal_confidence preserves the raw assessment so
  # fraud detection works on young channels too. Without this spec a future
  # refactor could silently re-introduce shrinkage and hide bot patterns on
  # young channels.
  it "preserves low TI for high-confidence dirty signals on cold-start channel (no upward shrinkage)" do
    channel4 = Channel.create!(twitch_id: "cs_dirty_ch", login: "cs_dirty", display_name: "ColdStartDirty")
    stream4 = Stream.create!(channel: channel4, started_at: 2.hours.ago, ended_at: 1.hour.ago)
    4.times { Stream.create!(channel: channel4, started_at: 3.hours.ago, ended_at: 2.hours.ago) }
    # Strong bot pattern: value=0.7 with full confidence on every signal
    result = engine.compute(signal_results: all_signals(value: 0.7, confidence: 1.0), stream: stream4, ccv: 1000)
    # ti_raw = (1.0 - 0.7) × 100 = 30; signal_confidence = 1.0 → Bayesian skipped
    # Pre-PR-F would have been 0.5 × 30 + 0.5 × 65 = 47.5 (suspicious→needs_review)
    # Post-PR-F stays at 30 → classification "suspicious"
    expect(result.ti_score).to be <= 35
    expect(result.classification).to eq("suspicious")
    expect(result.cold_start[:status]).to eq("provisional_low")
  end

  describe "philosophy v2: rehabilitation / penalty event / bonus accelerator code removed" do
    let(:result) { engine.compute(signal_results: all_signals(value: 0.1), stream: stream, ccv: 1000) }

    it "Result struct does not include rehabilitation_penalty/bonus members" do
      expect(result.members).not_to include(:rehabilitation_penalty, :rehabilitation_bonus)
    end

    it "removed constants raise NameError on resolution" do
      expect { TrustIndex::PenaltyEventEmitter }.to raise_error(NameError)
      expect { TrustIndex::RehabilitationCurve }.to raise_error(NameError)
      expect { TrustIndex::RehabilitationTracker }.to raise_error(NameError)
      expect { TrustIndex::BonusAcceleratorCalculator }.to raise_error(NameError)
      expect { Reputation::ComponentPercentileService }.to raise_error(NameError)
      expect { Reputation::PercentileService }.to raise_error(NameError)
      expect { RehabilitationPenaltyEvent }.to raise_error(NameError)
    end
  end

  # T1-074 PR2b — DEC-7 MF-1 symmetric publish adapter + MF-4 engine_version guard.
  describe "TI v2 dual-run adapters (DEC-7)" do
    let(:result) { engine.compute(signal_results: all_signals(value: 0.1), stream: stream, ccv: 1000) }

    it "#engine_version is 'v1'" do
      expect(result.engine_version).to eq("v1")
    end

    it "#to_headline_payload emits the CURRENT legacy wire shape (extension unchanged during shadow)" do
      payload = result.to_headline_payload
      expect(payload.keys).to contain_exactly(:ti_score, :classification, :erv_percent, :erv_count,
                                              :label, :label_color, :cold_start_status, :engine_version)
      expect(payload[:ti_score]).to eq(result.ti_score)
      expect(payload[:engine_version]).to eq("v1")
    end

    it "MF-4: persisted v1 TIH row is explicitly tagged engine_version='v1' (defense-in-depth; M1 default already 'v1')" do
      result
      expect(TrustIndexHistory.where(stream: stream).last.engine_version).to eq("v1")
    end
  end
end
