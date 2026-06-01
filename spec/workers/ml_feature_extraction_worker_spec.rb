# frozen_string_literal: true

require "rails_helper"

RSpec.describe MlFeatureExtractionWorker do
  let(:stream) { create(:stream) }
  let(:worker) { described_class.new }

  describe "sidekiq_options" do
    it "is enqueued on :post_stream queue (matches StreamerReputationRefreshWorker precedent)" do
      expect(described_class.sidekiq_options["queue"]).to eq("post_stream")
    end

    it "retry: 3 (matches post-stream worker convention)" do
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end
  end

  describe "#perform" do
    it "persists 1 StreamFeatureVector row per stream at SCHEMA_VERSION" do
      expect { worker.perform(stream.id) }.to change(StreamFeatureVector, :count).by(1)
      fv = StreamFeatureVector.find_by(stream_id: stream.id, version: Ml::FeatureExtractor::SCHEMA_VERSION)
      expect(fv).to be_present
      expect(fv.calculated_at).to be_within(5.seconds).of(Time.current)
    end

    it "is idempotent: re-running UPDATES the existing row instead of inserting" do
      worker.perform(stream.id)
      first_calc = StreamFeatureVector.find_by(stream_id: stream.id).calculated_at

      sleep 0.1
      expect { worker.perform(stream.id) }.not_to change(StreamFeatureVector, :count)

      fv = StreamFeatureVector.find_by(stream_id: stream.id)
      expect(fv.calculated_at).to be > first_calc
    end

    it "writes extractor_metadata jsonb" do
      worker.perform(stream.id)
      fv = StreamFeatureVector.find_by(stream_id: stream.id)
      expect(fv.extractor_metadata).to include(
        "schema_version" => Ml::FeatureExtractor::SCHEMA_VERSION,
        "stream_id" => stream.id,
        "insufficient_data_reasons" => {}
      )
    end

    it "all 25 feature columns are nil at PR1 (wireframe baseline)" do
      worker.perform(stream.id)
      fv = StreamFeatureVector.find_by(stream_id: stream.id)
      expect(fv.populated_feature_count).to eq(0)
    end

    it "warns + returns gracefully when stream not found (deleted between enqueue and execute)" do
      expect(Rails.logger).to receive(:warn).with(/stream nonexistent not found/)
      expect { worker.perform("nonexistent") }.not_to raise_error
      expect(StreamFeatureVector.count).to eq(0)
    end
  end
end
