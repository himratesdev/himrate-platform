# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR1 (framework wireframe): orchestrates per-stream-completion
# extraction of 25 LightGBM-ready tabular features. Delegates per-group implementation to
# `Ml::Features::*` service modules (added in PR2-7).
#
# Returns a Hash with all 25 feature keys; values are nil when source data insufficient
# (cold-start, no chatters, no CCV snapshots, etc.) — LightGBM trees handle NULL natively
# via missing-value splits. PR1 wireframe returns all-nil; per-feature implementations
# light up incrementally в PR2-7 (Viewer/Chat/Account/Growth/Stability/Maturity).
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
    end

    # Returns flat Hash of 25 feature keys → numeric values or nil (insufficient data).
    # Order matches StreamFeatureVector::FEATURE_COLUMNS for round-trip safety.
    def call
      {
        # Viewer (PR2) — Ml::Features::ViewerSignals
        chatter_to_ccv_ratio: nil,
        peak_to_average_ccv_ratio: nil,
        ccv_coefficient_of_variation: nil,
        ccv_tier_stickiness: nil,

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
        # PR2-7 will append per-group reasons (e.g., "viewer: insufficient_ccv_snapshots")
        insufficient_data_reasons: {}
      }
    end
  end
end
