# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR1: ActiveRecord model для stream_feature_vectors.
# 25 tabular features computed per-stream-completion by Ml::FeatureExtractor service +
# MlFeatureExtractionWorker. Composite PK (stream_id, version) supports schema evolution.
#
# All feature columns numeric or nullable — LightGBM tree models handle NULL natively
# via missing-value splits. Per-feature insufficient_data semantics handled at extractor
# service level (returns nil when data insufficient).
class StreamFeatureVector < ApplicationRecord
  self.primary_key = [ :stream_id, :version ]

  # CR-247 N1: explicit `validates :stream_id, presence: true` removed — Rails 8.1
  # `belongs_to :stream` is required by default (config.active_record.belongs_to_required_by_default = true),
  # so the explicit validation is a no-op duplicate.
  belongs_to :stream

  validates :version, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :calculated_at, presence: true

  # Latest version per stream for ML training queries.
  scope :latest_per_stream, -> { order(version: :desc) }

  # Sample for ML training window (last N days of completed streams).
  # CR-247 N2: dropped `where.not(calculated_at: nil)` — migration enforces
  # `t.datetime :calculated_at, null: false`, so the clause never excludes rows.
  scope :for_training_window, ->(window) { where("calculated_at > ?", window.ago) }

  # All 30 feature column names — used by ML training pipeline introspection
  # + spec assertions for completeness.
  FEATURE_COLUMNS = %i[
    chatter_to_ccv_ratio
    peak_to_average_ccv_ratio
    ccv_coefficient_of_variation
    ccv_tier_stickiness
    message_entropy
    unique_message_ratio
    single_message_chatter_ratio
    emote_only_ratio
    avg_inter_message_interval_sec
    timing_regularity_score
    nlp_contextual_relevance_score
    avg_account_age_days
    account_creation_date_clustering_gini
    profile_completeness_ratio
    engagement_participation_ratio
    follower_growth_cv_90d
    growth_engagement_correlation
    follow_unfollow_churn_rate
    attributed_spike_ratio
    trust_index_30d_std
    chat_rate_30d_cv
    viewer_retention_avg_sec
    account_age_days_capped
    total_streams_capped
    total_hours_capped
  ].freeze

  # Return features as flat hash for ML feature serving.
  def features
    FEATURE_COLUMNS.index_with { |col| public_send(col) }
  end

  # Count of non-null features (cold-start observability).
  def populated_feature_count
    FEATURE_COLUMNS.count { |col| !public_send(col).nil? }
  end
end
