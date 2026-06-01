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

      {
        # Viewer (PR2 — live) — Ml::Features::ViewerSignals
        chatter_to_ccv_ratio: viewer_features[:chatter_to_ccv_ratio],
        peak_to_average_ccv_ratio: viewer_features[:peak_to_average_ccv_ratio],
        ccv_coefficient_of_variation: viewer_features[:ccv_coefficient_of_variation],
        ccv_tier_stickiness: viewer_features[:ccv_tier_stickiness],

        # Chat (PR3) — Ml::Features::ChatSignals
        message_entropy: nil,
        unique_message_ratio: nil,
        single_message_chatter_ratio: nil,
        emote_only_ratio: nil,
        avg_inter_message_interval_sec: nil,
        timing_regularity_score: nil,
        nlp_contextual_relevance_score: nil,

        # Account (PR4) — Ml::Features::AccountSignals
        avg_account_age_days: nil,
        account_creation_date_clustering_gini: nil,
        profile_completeness_ratio: nil,
        engagement_participation_ratio: nil,

        # Growth (PR5) — Ml::Features::GrowthSignals
        follower_growth_cv_90d: nil,
        growth_engagement_correlation: nil,
        follow_unfollow_churn_rate: nil,
        attributed_spike_ratio: nil,

        # Stability (PR6) — Ml::Features::StabilitySignals
        trust_index_30d_std: nil,
        chat_rate_30d_cv: nil,
        viewer_retention_avg_sec: nil,

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
  end
end
