# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR3 — Chat signals (7 features) per BFT 15_ML-Pipeline.md §3.2.
#
# Data source: ClickHouse `chat_messages` table (post PR 1e-A cutover — CH is sole SoT for
# chat archive). Queries delegated to `Clickhouse::ChatQueries.chat_feature_aggregates`
# (single multi-aggregate SELECT, columnar-fast for typical per-stream chat ≤200k privmsgs).
#
# Of 7 BFT features, 6 are computed live in PR3 from chat_messages columnar aggregates.
# `nlp_contextual_relevance_score` is deferred — requires ONNX inference layer (rubert-tiny2
# или equivalent) which is a separate EPIC scope. Per [[feedback-no-throwaway-go-to-final-architecture]]:
# declining to build a placeholder heuristic IS the right call when proper ML implementation
# is known-final. Column stays nil with explicit reason `requires_nlp_inference_layer`.
module Ml
  module Features
    class ChatSignals
      MIN_MESSAGES_FOR_RATIO_FEATURES = 50 # below ~50 privmsgs the distribution-based stats are noise
      MIN_MESSAGES_FOR_TIMING = 10         # need ≥10 messages for meaningful inter-message stats

      def initialize(stream)
        @stream = stream
      end

      def call
        agg = aggregates

        # CR-250 PG-iter-3 test fix: nlp_contextual_relevance_score is STRUCTURALLY deferred
        # (separate ONNX EPIC) — its reason is always "requires_nlp_inference_layer_separate_epic"
        # regardless of chat data availability. The data-availability branches below must NOT
        # overwrite the NLP reason with "no_chat_data" / "insufficient_messages" / etc.
        nlp_score = nlp_contextual_relevance_score

        if agg.empty? || agg[:total_messages].to_i.zero?
          mark_data_dependent_insufficient("no_chat_data")
          return all_nil.merge(nlp_contextual_relevance_score: nlp_score)
        end

        total = agg[:total_messages]

        {
          message_entropy:                message_entropy(agg, total),
          unique_message_ratio:           unique_message_ratio(agg, total),
          single_message_chatter_ratio:   single_message_chatter_ratio(agg),
          emote_only_ratio:               emote_only_ratio(agg, total),
          avg_inter_message_interval_sec: avg_inter_message_interval_sec(agg, total),
          timing_regularity_score:        timing_regularity_score(agg, total),
          nlp_contextual_relevance_score: nlp_score
        }
      end

      def insufficient_data_reasons
        @insufficient_data_reasons ||= {}
      end

      private

      def aggregates
        @aggregates ||= Clickhouse::ChatQueries.chat_feature_aggregates(@stream)
      end

      # Shannon entropy of message_text distribution (bits). High entropy = diverse chat;
      # low = bot-like repetition. Aggregate computed CH-side; we just expose it.
      def message_entropy(agg, total)
        return record_insufficient(:message_entropy, "insufficient_messages") if total < MIN_MESSAGES_FOR_RATIO_FEATURES

        val = agg[:message_entropy_bits]
        return record_insufficient(:message_entropy, "ch_returned_nil_entropy") if val.nil?

        val.round(4)
      end

      def unique_message_ratio(agg, total)
        return record_insufficient(:unique_message_ratio, "insufficient_messages") if total < MIN_MESSAGES_FOR_RATIO_FEATURES

        (agg[:unique_messages].to_f / total).round(4)
      end

      # CR-250 N1: consistency with sibling ratio features — gate on MIN_MESSAGES_FOR_RATIO_FEATURES
      # before computing. A 2-message stream с 2 distinct chatters gives 1.0 but is statistically
      # noise for ML training. Lower noise floor would diverge от entropy/unique_message_ratio
      # semantics; better to keep all ratio features on the same 50-message threshold.
      def single_message_chatter_ratio(agg)
        total = agg[:total_messages].to_i
        return record_insufficient(:single_message_chatter_ratio, "insufficient_messages") if total < MIN_MESSAGES_FOR_RATIO_FEATURES

        unique = agg[:unique_chatters].to_i
        return record_insufficient(:single_message_chatter_ratio, "no_chatters") if unique.zero?

        (agg[:single_message_chatters].to_f / unique).round(4)
      end

      # BFT defines this as % of messages containing only emotes. Exact "only-emote" detection
      # requires per-message text-vs-emote-position diff (Twitch IRC `emotes` tag carries the
      # character ranges; an "only-emote" message has all non-whitespace ranges covered).
      # PR3 deliberately ships a TRACTABLE proxy: ratio of messages where the `emotes` field
      # is non-empty (i.e., the message CONTAINS at least one emote). This OVER-COUNTS mixed
      # text+emote messages vs the strict definition — but for bot-vs-human discrimination
      # the proxy is still strongly correlated (bot-spam messages tend to be either pure-text
      # ASCII или pure-emote rituals; humans mix). Refinement to "only-emote" requires
      # emote-range parsing per row — separate PR, won't change feature shape, ML can
      # retrain on the refined column when ready.
      def emote_only_ratio(agg, total)
        return record_insufficient(:emote_only_ratio, "insufficient_messages") if total < MIN_MESSAGES_FOR_RATIO_FEATURES

        (agg[:messages_with_emotes].to_f / total).round(4)
      end

      def avg_inter_message_interval_sec(agg, total)
        return record_insufficient(:avg_inter_message_interval_sec, "insufficient_messages") if total < MIN_MESSAGES_FOR_TIMING

        val = agg[:mean_inter_msg_sec]
        return record_insufficient(:avg_inter_message_interval_sec, "ch_returned_nil_mean") if val.nil?

        val.round(3)
      end

      # CV of inter-message intervals = std / mean. Low CV = regular cadence (bot-like);
      # high CV = bursty cadence (human chat patterns).
      def timing_regularity_score(agg, total)
        return record_insufficient(:timing_regularity_score, "insufficient_messages") if total < MIN_MESSAGES_FOR_TIMING

        mean = agg[:mean_inter_msg_sec]
        std = agg[:std_inter_msg_sec]
        return record_insufficient(:timing_regularity_score, "ch_returned_nil_stats") if mean.nil? || std.nil?
        return record_insufficient(:timing_regularity_score, "zero_mean_interval") if mean.zero?

        (std / mean).round(4)
      end

      # nlp_contextual_relevance_score: requires ONNX inference layer (rubert-tiny2 или
      # equivalent NLP model for context coherence scoring). Per BFT 15_ML-Pipeline.md §3.2.
      # Per [[feedback-no-throwaway-go-to-final-architecture]] — build the final ONNX-based
      # path as a separate EPIC instead of a heuristic placeholder that would be discarded.
      # Column stays nil with explicit deferred reason.
      def nlp_contextual_relevance_score
        record_insufficient(:nlp_contextual_relevance_score, "requires_nlp_inference_layer_separate_epic")
        nil
      end

      def all_nil
        {
          message_entropy: nil,
          unique_message_ratio: nil,
          single_message_chatter_ratio: nil,
          emote_only_ratio: nil,
          avg_inter_message_interval_sec: nil,
          timing_regularity_score: nil,
          nlp_contextual_relevance_score: nil
        }
      end

      # Mark data-dependent features (everything EXCEPT structurally-deferred NLP) с the given
      # reason. NLP keeps its own EPIC-deferral reason set by `nlp_contextual_relevance_score`.
      def mark_data_dependent_insufficient(reason)
        data_dependent = all_nil.keys - [ :nlp_contextual_relevance_score ]
        data_dependent.each { |k| insufficient_data_reasons[k] = reason }
      end

      def record_insufficient(feature_key, reason)
        insufficient_data_reasons[feature_key] = reason
        nil
      end
    end
  end
end
