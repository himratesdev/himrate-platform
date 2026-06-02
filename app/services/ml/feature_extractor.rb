# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR: orchestrates per-stream-completion extraction of 25
# LightGBM-ready tabular features. Delegates per-group implementation to
# `Ml::Features::*` service modules (Viewer + Chat + Account + Growth + Stability + Maturity).
#
# Returns a Hash with all 25 feature keys; values are nil when source data insufficient
# (cold-start, no chatters, no CCV snapshots, etc.) — LightGBM trees handle NULL natively
# via missing-value splits. Per-group implementations land incrementally; PR1 shipped the
# framework (all-nil), PR2 lights up Viewer (4 features), PR3-7 light up the rest.
#
# NB: BFT 15_ML-Pipeline.md §3.2 lists 30 entries, but 4 (auth_ratio, follower_only_mode,
# cross_channel_score, known_bot_ratio) are already live TI signals persisted в
# TrustIndexHistory.signal_breakdown JSON — ML training joins both tables, no duplication.
#
# Caller: MlFeatureExtractionWorker, triggered by PostStreamWorker after final TI compute.
module Ml
  class FeatureExtractor
    SCHEMA_VERSION = 1 # bump when feature set changes (renames, additions, removals)

    def initialize(stream)
      @stream = stream
      @insufficient_data_reasons = {}
    end

    # Returns flat Hash of 25 feature keys → numeric values or nil (insufficient data).
    # Order matches StreamFeatureVector::FEATURE_COLUMNS for round-trip safety.
    def call
      viewer_features = collect_viewer_features
      chat_features = collect_chat_features
      account_features = collect_account_features
      growth_features = collect_growth_features
      stability_features = collect_stability_features

      {
        # Viewer (PR2 — live) — Ml::Features::ViewerSignals
        chatter_to_ccv_ratio: viewer_features[:chatter_to_ccv_ratio],
        peak_to_average_ccv_ratio: viewer_features[:peak_to_average_ccv_ratio],
        ccv_coefficient_of_variation: viewer_features[:ccv_coefficient_of_variation],
        ccv_tier_stickiness: viewer_features[:ccv_tier_stickiness],

        # Chat (PR3 — live, 6/7) — Ml::Features::ChatSignals.
        # nlp_contextual_relevance_score deferred to separate ONNX-NLP EPIC (per
        # [[feedback-no-throwaway-go-to-final-architecture]] — no heuristic placeholder).
        message_entropy: chat_features[:message_entropy],
        unique_message_ratio: chat_features[:unique_message_ratio],
        single_message_chatter_ratio: chat_features[:single_message_chatter_ratio],
        emote_only_ratio: chat_features[:emote_only_ratio],
        avg_inter_message_interval_sec: chat_features[:avg_inter_message_interval_sec],
        timing_regularity_score: chat_features[:timing_regularity_score],
        nlp_contextual_relevance_score: chat_features[:nlp_contextual_relevance_score],

        # Account (PR4 — live) — Ml::Features::AccountSignals
        avg_account_age_days: account_features[:avg_account_age_days],
        account_creation_date_clustering_gini: account_features[:account_creation_date_clustering_gini],
        profile_completeness_ratio: account_features[:profile_completeness_ratio],
        engagement_participation_ratio: account_features[:engagement_participation_ratio],

        # Growth (PR5 — live) — Ml::Features::GrowthSignals
        follower_growth_cv_90d: growth_features[:follower_growth_cv_90d],
        growth_engagement_correlation: growth_features[:growth_engagement_correlation],
        follow_unfollow_churn_rate: growth_features[:follow_unfollow_churn_rate],
        attributed_spike_ratio: growth_features[:attributed_spike_ratio],

        # Stability (PR6 — live, 2/3) — Ml::Features::StabilitySignals.
        # viewer_retention_avg_sec deferred to separate viewer_session_tracking EPIC
        # (per [[feedback-no-throwaway-go-to-final-architecture]] — chat-only proxy would
        # bias against the lurker majority).
        trust_index_30d_std: stability_features[:trust_index_30d_std],
        chat_rate_30d_cv: stability_features[:chat_rate_30d_cv],
        viewer_retention_avg_sec: stability_features[:viewer_retention_avg_sec],

        # Maturity (PR7) — Ml::Features::MaturitySignals
        account_age_days_capped: nil,
        total_streams_capped: nil,
        total_hours_capped: nil
      }
    end

    def metadata
      {
        schema_version: SCHEMA_VERSION,
        stream_id: @stream.id,
        insufficient_data_reasons: @insufficient_data_reasons
      }
    end

    private

    def collect_viewer_features
      viewer = Ml::Features::ViewerSignals.new(@stream)
      features = viewer.call
      reasons = viewer.insufficient_data_reasons
      @insufficient_data_reasons[:viewer] = reasons if reasons.any?
      features
    end

    def collect_chat_features
      chat = Ml::Features::ChatSignals.new(@stream)
      features = chat.call
      reasons = chat.insufficient_data_reasons
      @insufficient_data_reasons[:chat] = reasons if reasons.any?
      features
    end

    def collect_account_features
      account = Ml::Features::AccountSignals.new(@stream)
      features = account.call
      reasons = account.insufficient_data_reasons
      @insufficient_data_reasons[:account] = reasons if reasons.any?
      features
    end

    def collect_growth_features
      growth = Ml::Features::GrowthSignals.new(@stream)
      features = growth.call
      reasons = growth.insufficient_data_reasons
      @insufficient_data_reasons[:growth] = reasons if reasons.any?
      features
    end

    def collect_stability_features
      stability = Ml::Features::StabilitySignals.new(@stream)
      features = stability.call
      reasons = stability.insufficient_data_reasons
      @insufficient_data_reasons[:stability] = reasons if reasons.any?
      features
    end
  end
end
