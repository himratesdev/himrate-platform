# frozen_string_literal: true

require "rails_helper"

RSpec.describe MlFeatureExtractionWorker do
  let(:stream) { create(:stream) }
  let(:worker) { described_class.new }

  describe "sidekiq_options" do
    it "is enqueued on :post_stream queue (matches StreamerReputationRefreshWorker precedent)" do
      # Sidekiq stores sidekiq_options verbatim — worker declares `queue: :post_stream`
      # (symbol), matching StreamerReputationRefreshWorker which uses the same symbol form.
      # Compare as-is. Note: PR #229 / #246 workers use STRING form
      # (`queue: "stream_lifecycle"`); both forms are valid in Sidekiq, must match worker
      # declaration verbatim in spec.
      expect(described_class.sidekiq_options["queue"]).to eq(:post_stream)
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

    # CR-249 M2 (iter-2): PR2 made viewer features live → cold-start streams (no snapshots)
    # now correctly populate `insufficient_data_reasons[:viewer]` для всех 4 viewer features.
    # Seed enough source data to exercise the happy-path metadata shape (empty reasons),
    # which matches the test's stated intent (verify jsonb structure + schema_version).
    it "writes extractor_metadata jsonb (happy-path, all viewer data sufficient)" do
      # ≥3 CCV snapshots + ≥3 chatters snapshots + ≥30 prior streams с avg_ccv
      # → ViewerSignals returns 4 numeric features, no insufficient reasons.
      3.times { |i| create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: (5 - i).minutes.ago) }
      3.times { |i| create(:chatters_snapshot, stream: stream, unique_chatters_count: 50, timestamp: (5 - i).minutes.ago) }
      # Mark current stream completed + seed 29 prior so longitudinal CV has ≥3 history.
      stream.update!(ended_at: Time.current, avg_ccv: 500)
      29.times { |i| create(:stream, channel: stream.channel, ended_at: (i + 1).hours.ago, avg_ccv: 500) }

      worker.perform(stream.id)
      fv = StreamFeatureVector.find_by(stream_id: stream.id)
      expect(fv.extractor_metadata).to include(
        "schema_version" => Ml::FeatureExtractor::SCHEMA_VERSION,
        "stream_id" => stream.id,
        "insufficient_data_reasons" => {}
      )
    end

    # CR-249 N1 fold-in (iter-2): copy update — cold-start stream still gets nil for
    # all 25 features (viewer signals return nil under their insufficient-data branches
    # for streams без CCV/chatters/history). Assertion stays valid; comment renamed.
    it "all 25 feature columns are nil for cold-start stream (no snapshots / no history)" do
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
