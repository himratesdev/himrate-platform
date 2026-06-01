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

  describe "#call (PR1 framework wireframe)" do
    it "returns hash with all 25 feature keys" do
      result = extractor.call
      expect(result).to be_a(Hash)
      expect(result.keys).to match_array(StreamFeatureVector::FEATURE_COLUMNS)
    end

    it "all feature values are nil at PR1 (implementations land in PR2-7)" do
      result = extractor.call
      expect(result.values).to all(be_nil)
    end
  end

  describe "#metadata" do
    it "returns schema version + stream id + empty insufficient_data_reasons at PR1" do
      meta = extractor.metadata
      expect(meta[:schema_version]).to eq(described_class::SCHEMA_VERSION)
      expect(meta[:stream_id]).to eq(stream.id)
      expect(meta[:insufficient_data_reasons]).to eq({})
    end
  end
end
