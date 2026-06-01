# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::FeatureExtractor do
  let(:stream) { create(:stream) }
  let(:extractor) { described_class.new(stream) }

  describe "SCHEMA_VERSION" do
    it "is integer 1 at PR1" do
      expect(described_class::SCHEMA_VERSION).to eq(1)
    end
  end

  describe "#call" do
    it "returns hash with all 25 feature keys (matches StreamFeatureVector::FEATURE_COLUMNS)" do
      result = extractor.call
      expect(result).to be_a(Hash)
      expect(result.keys).to match_array(StreamFeatureVector::FEATURE_COLUMNS)
    end

    it "PR3-7 groups still nil (Chat/Account/Growth/Stability/Maturity yet to land)" do
      result = extractor.call
      non_viewer_keys = StreamFeatureVector::FEATURE_COLUMNS - %i[
        chatter_to_ccv_ratio peak_to_average_ccv_ratio ccv_coefficient_of_variation ccv_tier_stickiness
      ]
      non_viewer_keys.each do |k|
        expect(result[k]).to be_nil, "expected #{k} to be nil pending PR3-7"
      end
    end

    # PR2: ViewerSignals delegation — extractor returns numeric viewer features when data
    # sufficient. ViewerSignals service has its own per-feature edge-case specs; here we
    # just verify the wire-up.
    it "delegates viewer features to Ml::Features::ViewerSignals (PR2)" do
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 5.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 4.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 3.minutes.ago)
      create(:chatters_snapshot, stream: stream, unique_chatters_count: 50, total_messages_count: 0, timestamp: 5.minutes.ago)

      result = extractor.call
      expect(result[:ccv_tier_stickiness]).to eq(1.0) # mean=500 exactly at tier
      expect(result[:peak_to_average_ccv_ratio]).to eq(1.0)
      expect(result[:chatter_to_ccv_ratio]).to be_within(0.001).of(0.1)
    end
  end

  describe "#metadata" do
    it "schema_version + stream_id + empty insufficient_data_reasons when all features computed" do
      allow_any_instance_of(Ml::Features::ViewerSignals).to receive(:call).and_return(
        chatter_to_ccv_ratio: 0.3, peak_to_average_ccv_ratio: 1.5,
        ccv_coefficient_of_variation: 0.2, ccv_tier_stickiness: 0.8
      )
      allow_any_instance_of(Ml::Features::ViewerSignals).to receive(:insufficient_data_reasons).and_return({})
      extractor.call

      meta = extractor.metadata
      expect(meta[:schema_version]).to eq(described_class::SCHEMA_VERSION)
      expect(meta[:stream_id]).to eq(stream.id)
      expect(meta[:insufficient_data_reasons]).to eq({})
    end

    it "captures per-group insufficient_data_reasons when features go nil" do
      extractor.call # no CCV snapshots → viewer reports 4 reasons

      meta = extractor.metadata
      expect(meta[:insufficient_data_reasons]).to have_key(:viewer)
      expect(meta[:insufficient_data_reasons][:viewer].keys).to include(:chatter_to_ccv_ratio)
    end
  end
end
