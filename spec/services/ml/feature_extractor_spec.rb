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

    it "PR4-7 groups still nil (Account/Growth/Stability/Maturity yet to land)" do
      # Stub CH calls to avoid live Clickhouse hits в test env (PR3 chat features delegate)
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})

      result = extractor.call
      pr47_pending_keys = StreamFeatureVector::FEATURE_COLUMNS - %i[
        chatter_to_ccv_ratio peak_to_average_ccv_ratio ccv_coefficient_of_variation ccv_tier_stickiness
        message_entropy unique_message_ratio single_message_chatter_ratio emote_only_ratio
        avg_inter_message_interval_sec timing_regularity_score nlp_contextual_relevance_score
      ]
      pr47_pending_keys.each do |k|
        expect(result[k]).to be_nil, "expected #{k} to be nil pending PR4-7"
      end
    end

    # PR2: ViewerSignals delegation — extractor returns numeric viewer features when data
    # sufficient. ViewerSignals service has its own per-feature edge-case specs; here we
    # just verify the wire-up.
    it "delegates viewer features to Ml::Features::ViewerSignals (PR2)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 5.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 4.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 3.minutes.ago)
      create(:chatters_snapshot, stream: stream, unique_chatters_count: 50, total_messages_count: 0, timestamp: 5.minutes.ago)

      result = extractor.call
      expect(result[:ccv_tier_stickiness]).to eq(1.0) # mean=500 exactly at tier
      expect(result[:peak_to_average_ccv_ratio]).to eq(1.0)
      expect(result[:chatter_to_ccv_ratio]).to be_within(0.001).of(0.1)
    end

    # PR3: ChatSignals delegation — extractor returns numeric chat features when CH aggregates
    # are sufficient. ChatSignals service has its own per-feature edge-case specs.
    it "delegates chat features to Ml::Features::ChatSignals (PR3)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 1000, unique_messages: 700, unique_chatters: 200,
        messages_with_emotes: 300, single_message_chatters: 60,
        message_entropy_bits: 5.5, mean_inter_msg_sec: 0.6, std_inter_msg_sec: 0.3
      )

      result = extractor.call
      expect(result[:message_entropy]).to eq(5.5)
      expect(result[:unique_message_ratio]).to eq(0.7)
      expect(result[:timing_regularity_score]).to eq(0.5)
      expect(result[:nlp_contextual_relevance_score]).to be_nil # deferred ONNX EPIC
    end
  end

  describe "#metadata" do
    it "schema_version + stream_id + empty insufficient_data_reasons when all features computed" do
      allow_any_instance_of(Ml::Features::ViewerSignals).to receive(:call).and_return(
        chatter_to_ccv_ratio: 0.3, peak_to_average_ccv_ratio: 1.5,
        ccv_coefficient_of_variation: 0.2, ccv_tier_stickiness: 0.8
      )
      allow_any_instance_of(Ml::Features::ViewerSignals).to receive(:insufficient_data_reasons).and_return({})
      # PR3: also stub ChatSignals для all-features-computed scenario
      allow_any_instance_of(Ml::Features::ChatSignals).to receive(:call).and_return(
        message_entropy: 5.0, unique_message_ratio: 0.6,
        single_message_chatter_ratio: 0.3, emote_only_ratio: 0.2,
        avg_inter_message_interval_sec: 0.8, timing_regularity_score: 0.4,
        nlp_contextual_relevance_score: 0.7
      )
      allow_any_instance_of(Ml::Features::ChatSignals).to receive(:insufficient_data_reasons).and_return({})
      extractor.call

      meta = extractor.metadata
      expect(meta[:schema_version]).to eq(described_class::SCHEMA_VERSION)
      expect(meta[:stream_id]).to eq(stream.id)
      expect(meta[:insufficient_data_reasons]).to eq({})
    end

    it "captures per-group insufficient_data_reasons when features go nil" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      extractor.call # no CCV snapshots → viewer reports 4 reasons; no chat → chat reports 7 reasons

      meta = extractor.metadata
      expect(meta[:insufficient_data_reasons]).to have_key(:viewer)
      expect(meta[:insufficient_data_reasons]).to have_key(:chat)
      expect(meta[:insufficient_data_reasons][:viewer].keys).to include(:chatter_to_ccv_ratio)
      expect(meta[:insufficient_data_reasons][:chat][:nlp_contextual_relevance_score]).to eq("requires_nlp_inference_layer_separate_epic")
    end
  end
end
