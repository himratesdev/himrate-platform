# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Features::ChatSignals do
  let(:stream) { create(:stream) }
  let(:chat) { described_class.new(stream) }

  describe "#call (no chat data)" do
    before do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return({})
    end

    it "returns all-nil hash for stream без chat" do
      result = chat.call
      expect(result.values).to all(be_nil)
      expect(result.keys).to match_array(%i[
        message_entropy unique_message_ratio single_message_chatter_ratio
        emote_only_ratio avg_inter_message_interval_sec timing_regularity_score
        nlp_contextual_relevance_score
      ])
    end

    it "marks 6 data-dependent features 'no_chat_data' + NLP keeps deferred-EPIC reason" do
      chat.call
      reasons = chat.insufficient_data_reasons
      expect(reasons.keys).to match_array(%i[
        message_entropy unique_message_ratio single_message_chatter_ratio
        emote_only_ratio avg_inter_message_interval_sec timing_regularity_score
        nlp_contextual_relevance_score
      ])
      # 6 data-dependent features → "no_chat_data"; NLP keeps its structural deferral reason.
      expect(reasons.values.tally).to eq(
        "no_chat_data" => 6,
        "requires_nlp_inference_layer_separate_epic" => 1
      )
      expect(reasons[:nlp_contextual_relevance_score]).to eq("requires_nlp_inference_layer_separate_epic")
    end
  end

  describe "#call (happy-path — sufficient data)" do
    before do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 1000,
        unique_messages: 700,
        unique_chatters: 200,
        messages_with_emotes: 300,
        single_message_chatters: 60,
        message_entropy_bits: 5.5,
        mean_inter_msg_sec: 0.6,
        std_inter_msg_sec: 0.3
      )
    end

    it "computes message_entropy verbatim from CH aggregate" do
      expect(chat.call[:message_entropy]).to eq(5.5)
    end

    it "computes unique_message_ratio = unique/total" do
      expect(chat.call[:unique_message_ratio]).to eq(0.7)
    end

    it "computes single_message_chatter_ratio = single/unique_chatters" do
      expect(chat.call[:single_message_chatter_ratio]).to eq(0.3)
    end

    it "computes emote_only_ratio as proxy (messages_with_emotes/total)" do
      expect(chat.call[:emote_only_ratio]).to eq(0.3)
    end

    it "computes avg_inter_message_interval_sec from CH mean" do
      expect(chat.call[:avg_inter_message_interval_sec]).to eq(0.6)
    end
  end

  # CR-252 S1 (PR4 hotfix): regression test для MAX_INTER_MESSAGE_INTERVAL_SEC cap.
  # DV PR #251 caught real value 9.27M sec overflowing numeric(10,3). Hotfix adds 24h
  # sanity cap in service layer + widens column. Without this regression test, a future
  # refactor could silently drop the cap и reintroduce overflow path.
  describe "#call (outlier cap — PR4 hotfix regression)" do
    before do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 100, unique_messages: 50, unique_chatters: 20,
        messages_with_emotes: 0, single_message_chatters: 5,
        message_entropy_bits: 4.0,
        mean_inter_msg_sec: 9_272_712.0, # actual persisted MAX from staging — pre-cap overflows numeric(10,3)
        std_inter_msg_sec: 100.0
      )
    end

    it "caps avg_inter_message_interval_sec at MAX_INTER_MESSAGE_INTERVAL_SEC (24h)" do
      expect(chat.call[:avg_inter_message_interval_sec]).to eq(described_class::MAX_INTER_MESSAGE_INTERVAL_SEC.to_f)
    end

    it "preserves sub-cap values unchanged" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 100, unique_messages: 50, unique_chatters: 20,
        messages_with_emotes: 0, single_message_chatters: 5,
        message_entropy_bits: 4.0,
        mean_inter_msg_sec: 3600.5, # 1h — well below 24h cap
        std_inter_msg_sec: 100.0
      )
      expect(chat.call[:avg_inter_message_interval_sec]).to eq(3600.5)
    end

    it "computes timing_regularity_score as CV (std/mean)" do
      expect(chat.call[:timing_regularity_score]).to eq(0.5) # 0.3/0.6
    end

    it "nlp_contextual_relevance_score deferred — returns nil + records reason" do
      expect(chat.call[:nlp_contextual_relevance_score]).to be_nil
      expect(chat.insufficient_data_reasons[:nlp_contextual_relevance_score]).to eq("requires_nlp_inference_layer_separate_epic")
    end
  end

  describe "#call (insufficient — below MIN_MESSAGES_FOR_RATIO_FEATURES)" do
    before do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 30, # < MIN_MESSAGES_FOR_RATIO_FEATURES (50)
        unique_messages: 25,
        unique_chatters: 15,
        messages_with_emotes: 5,
        single_message_chatters: 8,
        message_entropy_bits: 4.1,
        mean_inter_msg_sec: 1.0,
        std_inter_msg_sec: 0.5
      )
    end

    it "marks ratio-based features insufficient (< 50 messages)" do
      chat.call
      expect(chat.insufficient_data_reasons).to include(
        message_entropy: "insufficient_messages",
        unique_message_ratio: "insufficient_messages",
        emote_only_ratio: "insufficient_messages"
      )
    end

    it "timing features still compute (require only 10+ messages)" do
      result = chat.call
      expect(result[:avg_inter_message_interval_sec]).to eq(1.0)
      expect(result[:timing_regularity_score]).to eq(0.5)
    end

    # CR-250 N1 iter-2: single_message_chatter_ratio now gates on MIN_MESSAGES_FOR_RATIO_FEATURES
    # consistent with sibling ratio features (entropy, unique_msg, emote_only).
    it "single_message_chatter_ratio also marked insufficient (< 50 messages)" do
      chat.call
      expect(chat.insufficient_data_reasons[:single_message_chatter_ratio]).to eq("insufficient_messages")
    end
  end

  describe "#call (zero-mean timing edge case)" do
    before do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 100,
        unique_messages: 50,
        unique_chatters: 20,
        messages_with_emotes: 0,
        single_message_chatters: 5,
        message_entropy_bits: 4.0,
        mean_inter_msg_sec: 0.0, # all messages с same timestamp — pathological
        std_inter_msg_sec: 0.0
      )
    end

    it "timing_regularity_score nil with zero mean (avoid division)" do
      expect(chat.call[:timing_regularity_score]).to be_nil
      expect(chat.insufficient_data_reasons[:timing_regularity_score]).to eq("zero_mean_interval")
    end
  end

  describe "#call (no chatters edge case)" do
    before do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 100,
        unique_messages: 50,
        unique_chatters: 0, # absurd but possible if all usernames blank
        messages_with_emotes: 10,
        single_message_chatters: 0,
        message_entropy_bits: 4.0,
        mean_inter_msg_sec: 1.0,
        std_inter_msg_sec: 0.5
      )
    end

    it "single_message_chatter_ratio nil with zero unique chatters" do
      expect(chat.call[:single_message_chatter_ratio]).to be_nil
      expect(chat.insufficient_data_reasons[:single_message_chatter_ratio]).to eq("no_chatters")
    end
  end
end
