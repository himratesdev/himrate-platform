# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::ChatterCcvRatio do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "default", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.10 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.10 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "just_chatting", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.20 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "esports", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.02 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "gaming", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.04 }
  end

  it "returns ~0 for normal JC stream at CCV_REFERENCE (shrink=1.0)" do
    # 250/1000 = 0.25 >= 0.20 baseline (just_chatting) → value 0
    result = signal.calculate(unique_chatters_60min: 250, latest_ccv: 1000, category: "just_chatting", stream_duration_min: 60)
    expect(result.value).to eq(0.0)
    expect(result.metadata[:shrink]).to eq(1.0)
  end

  it "returns high value for botted stream (very few chatters vs CCV)" do
    # 10/1000 = 0.01, baseline 0.10 → value = (0.10 - 0.01) / 0.10 = 0.9
    result = signal.calculate(unique_chatters_60min: 10, latest_ccv: 1000, category: "default", stream_duration_min: 60)
    expect(result.value).to be > 0.5
  end

  it "returns ~0 for esports with low chatter ratio (1:50 = normal)" do
    result = signal.calculate(unique_chatters_60min: 100, latest_ccv: 5000, category: "esports", stream_duration_min: 60)
    expect(result.value).to eq(0.0)
  end

  it "returns nil when no IRC data" do
    result = signal.calculate(unique_chatters_60min: nil, latest_ccv: 1000, category: "default")
    expect(result.value).to be_nil
  end

  it "returns nil when CCV = 0" do
    result = signal.calculate(unique_chatters_60min: 50, latest_ccv: 0, category: "default")
    expect(result.value).to be_nil
  end

  describe "Phase 4 J PR-B — CCV-aware baseline shrink + safe fallback" do
    it "applies shrink=1.0 at CCV_REFERENCE (1000)" do
      result = signal.calculate(unique_chatters_60min: 40, latest_ccv: 1000, category: "gaming", stream_duration_min: 60)
      # baseline 0.04 × 1.0 = 0.04. ratio 0.04 → exactly at threshold → value 0
      expect(result.metadata[:shrink]).to eq(1.0)
      expect(result.metadata[:expected_min]).to eq(0.04)
      expect(result.value).to eq(0.0)
    end

    it "applies floor shrink at very high CCV (≥ CCV_REFERENCE/MIN_SHRINK)" do
      # 6500 ccv (Recrent-like): 1000/6500 = 0.154 → clamp(0.3) → 0.3
      result = signal.calculate(unique_chatters_60min: 550, latest_ccv: 6500, category: "gaming", stream_duration_min: 60)
      expect(result.metadata[:shrink]).to eq(0.3)
      # effective baseline 0.04 × 0.3 = 0.012. ratio 550/6500 = 0.0846 >> 0.012 → value 0
      expect(result.metadata[:expected_min]).to eq(0.012)
      expect(result.value).to eq(0.0)
    end

    it "Recrent-like honest big channel (6482 ccv, gaming) now clears threshold" do
      result = signal.calculate(unique_chatters_60min: 552, latest_ccv: 6482, category: "gaming", stream_duration_min: 60)
      # pre-PR-B with hardcoded fallback 0.10: ratio 0.0852 < 0.10 → value 0.148 (drag)
      # post-PR-B with gaming 0.04 × shrink 0.3 = 0.012: ratio 0.0852 >> 0.012 → value 0 ✅
      expect(result.value).to eq(0.0)
    end

    it "zackrawrr-like very-big channel (45k ccv) clears threshold at typical 2% ratio" do
      result = signal.calculate(unique_chatters_60min: 900, latest_ccv: 45000, category: "gaming", stream_duration_min: 60)
      # baseline 0.04 × 0.3 = 0.012. ratio 0.020 >> 0.012 → value 0 ✅
      expect(result.value).to eq(0.0)
      expect(result.metadata[:shrink]).to eq(0.3)
    end

    it "small streamer (200 ccv) keeps configured baseline (shrink stays 1.0)" do
      result = signal.calculate(unique_chatters_60min: 10, latest_ccv: 200, category: "default", stream_duration_min: 60)
      # baseline 0.10 × 1.0 = 0.10. ratio 0.05 → value = (0.10 - 0.05) / 0.10 = 0.5
      expect(result.metadata[:shrink]).to eq(1.0)
      expect(result.value).to be > 0.4
    end

    it "falls through to default category when the named category is uncalibrated" do
      result = signal.calculate(unique_chatters_60min: 100, latest_ccv: 5000, category: "newly_added_uncalibrated_category", stream_duration_min: 60)
      # SignalConfiguration.params_for retries with category="default" when the
      # named category returns no rows; default has expected_ratio_min seeded so
      # the signal resolves rather than abstaining. This documents the lookup
      # behavior — only when the row is entirely missing (next example) does the
      # signal abstain.
      expect(result.value).not_to be_nil
    end

    it "abstains cleanly when expected_ratio_min row missing (would have used 0.10 fallback pre-PR)" do
      # Delete just expected_ratio_min rows; weight_in_ti stays → params resolve to a
      # hash without the baseline key. Pre-PR-B signal would have silently used the
      # 0.10 hardcoded fallback (producing the median TI=77 floor on big streams).
      # Post-PR-B: insufficient with reason "no_baseline_config" + confidence=0.0 so
      # Engine#compute_raw_ti's confidence>0 filter drops it cleanly.
      SignalConfiguration.where(signal_type: "chatter_ccv_ratio", param_name: "expected_ratio_min").delete_all

      result = signal.calculate(unique_chatters_60min: 100, latest_ccv: 5000, category: "default", stream_duration_min: 60)
      expect(result.value).to be_nil
      expect(result.confidence).to eq(0.0)
      expect(result.metadata[:reason]).to eq("no_baseline_config")
    end
  end
end
