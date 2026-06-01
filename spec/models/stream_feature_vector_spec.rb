# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamFeatureVector do
  let(:stream) { create(:stream) }

  describe "associations" do
    it { is_expected.to belong_to(:stream) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:stream_id) }
    it { is_expected.to validate_presence_of(:calculated_at) }
    it { is_expected.to validate_presence_of(:version) }
  end

  describe "FEATURE_COLUMNS" do
    it "lists exactly 25 numeric + 3 capped maturity columns = 25 numeric/decimal columns" do
      # 4 viewer + 7 chat + 4 account + 4 growth + 3 stability + 3 maturity = 25
      expect(described_class::FEATURE_COLUMNS.size).to eq(25)
    end

    it "all column names map to actual DB columns" do
      column_names = described_class.column_names.map(&:to_sym)
      described_class::FEATURE_COLUMNS.each do |col|
        expect(column_names).to include(col), "FEATURE_COLUMNS includes :#{col} but no matching DB column"
      end
    end
  end

  describe "#features" do
    it "returns hash of all 25 feature columns with current values (nil-safe)" do
      fv = create(:stream_feature_vector, stream: stream)
      expect(fv.features).to be_a(Hash)
      expect(fv.features.keys).to match_array(described_class::FEATURE_COLUMNS)
      expect(fv.features.values).to all(be_nil) # PR1 wireframe — all features nil
    end
  end

  describe "#populated_feature_count" do
    it "returns 0 for all-nil wireframe (PR1 baseline)" do
      fv = create(:stream_feature_vector, stream: stream)
      expect(fv.populated_feature_count).to eq(0)
    end

    it "counts non-nil features when some populated" do
      fv = create(:stream_feature_vector, stream: stream,
                  chatter_to_ccv_ratio: 0.85,
                  message_entropy: 4.2,
                  account_age_days_capped: 365)
      expect(fv.populated_feature_count).to eq(3)
    end
  end

  describe "composite primary key (stream_id, version)" do
    it "allows multiple versions per stream" do
      create(:stream_feature_vector, stream: stream, version: 1)
      expect {
        create(:stream_feature_vector, stream: stream, version: 2)
      }.not_to raise_error
      expect(stream.feature_vectors.count).to eq(2)
    end

    it "prevents duplicate (stream_id, version) inserts" do
      create(:stream_feature_vector, stream: stream, version: 1)
      expect {
        create(:stream_feature_vector, stream: stream, version: 1)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".for_training_window" do
    it "filters streams calculated within given lookback window" do
      old_fv = create(:stream_feature_vector, stream: create(:stream), calculated_at: 100.days.ago)
      recent_fv = create(:stream_feature_vector, stream: create(:stream), calculated_at: 1.day.ago)

      result = described_class.for_training_window(30.days)
      expect(result).to include(recent_fv)
      expect(result).not_to include(old_fv)
    end
  end
end
