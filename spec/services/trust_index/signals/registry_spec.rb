# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::Registry do
  before do
    # Seed minimal signal configurations for tests
    TiSignal::SIGNAL_TYPES.each do |type|
      SignalConfiguration.find_or_create_by!(
        signal_type: type, category: "default", param_name: "weight_in_ti"
      ) { |c| c.param_value = 0.1 }

      SignalConfiguration.find_or_create_by!(
        signal_type: type, category: "default", param_name: "alert_threshold"
      ) { |c| c.param_value = 0.5 }
    end

    # Auth ratio thresholds
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "default", param_name: "expected_min"
    ) { |c| c.param_value = 0.65 }

    # Chatter ratio thresholds
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "default", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.10 }
  end

  describe ".all" do
    it "returns 11 signal instances" do
      signals = described_class.all
      expect(signals.size).to eq(11)
      expect(signals).to all(be_a(TrustIndex::Signals::BaseSignal))
    end

    it "each signal has unique signal_type" do
      types = described_class.all.map(&:signal_type)
      expect(types.uniq.size).to eq(11)
      expect(types).to match_array(TiSignal::SIGNAL_TYPES)
    end

    it "each signal responds to #calculate, #name, #weight" do
      described_class.all.each do |signal|
        expect(signal).to respond_to(:calculate, :name, :weight, :signal_type)
      end
    end
  end

  describe ".compute_all" do
    let(:context) { { latest_ccv: nil, latest_chatters: nil, category: "default" } }

    it "returns hash with 11 keys" do
      results = described_class.compute_all(context)
      expect(results.size).to eq(11)
      expect(results.keys).to match_array(TiSignal::SIGNAL_TYPES)
    end

    it "each result is a BaseSignal::Result" do
      results = described_class.compute_all(context)
      results.each_value do |r|
        expect(r).to be_a(TrustIndex::Signals::BaseSignal::Result)
      end
    end

    it "isolates errors — one failing signal doesn't block others" do
      allow_any_instance_of(TrustIndex::Signals::AuthRatio).to receive(:calculate).and_raise(StandardError, "boom")
      results = described_class.compute_all(context)
      expect(results["auth_ratio"].value).to be_nil
      expect(results["auth_ratio"].metadata[:error]).to eq("StandardError")
      # Other signals still computed
      expect(results.values.count { |r| r.metadata[:error].nil? }).to be >= 10
    end
  end

  describe ".find" do
    it "finds signal by type" do
      signal = described_class.find("auth_ratio")
      expect(signal).to be_a(TrustIndex::Signals::AuthRatio)
    end

    it "raises for unknown type" do
      expect { described_class.find("nonexistent") }.to raise_error(ArgumentError)
    end
  end
end
