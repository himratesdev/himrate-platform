# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR1: stream_feature_vectors — LightGBM-ready tabular features
# computed per-stream-completion. 25 columns per BFT 15_ML-Pipeline.md §3.2, 6 feature groups:
# Viewer (4) · Chat (7) · Account (4) · Growth (4) · Stability (3) · Maturity (3).
#
# NB on the "30 vs 25" delta: BFT §3.2 lists 30 entries, but 4 of those (auth_ratio,
# follower_only_mode, cross_channel_score, known_bot_ratio) are LIVE TI signals already
# computed by `app/services/trust_index/signals/` and persisted in TrustIndexHistory.
# Duplicating them as feature_vector columns would create a sync hazard. ML training will
# join `stream_feature_vectors` with `trust_index_histories` via stream_id. The 5th BFT
# entry (`peak_to_average_ccv_ratio`) IS here as a feature (just relisted under "Viewer").
#
# Composite PK (stream_id, version) — version stamps allow schema evolution without
# data loss (rerun new extractor on existing streams, keep old version for ML model
# backward compat).
#
# All feature columns nullable: cold-start streams (<3 viewers, <15 ccv snapshots, etc.)
# get NULL for features that need that data; LightGBM trees handle NULL natively via
# missing-value handling. Per-feature insufficient_data semantics live in the extractor
# services, not in DB defaults.
class CreateStreamFeatureVectors < ActiveRecord::Migration[8.0]
  def up
    create_table :stream_feature_vectors, id: false, primary_key: [ :stream_id, :version ] do |t|
      t.uuid :stream_id, null: false
      t.integer :version, null: false, default: 1
      t.datetime :calculated_at, null: false, precision: 6

      # === Viewer signals (4) — from CcvSnapshot + ChattersSnapshot ===
      t.decimal :chatter_to_ccv_ratio, precision: 8, scale: 4
      t.decimal :peak_to_average_ccv_ratio, precision: 8, scale: 4
      t.decimal :ccv_coefficient_of_variation, precision: 8, scale: 4
      t.decimal :ccv_tier_stickiness, precision: 8, scale: 4

      # === Chat signals (7) — from ClickHouse chat_messages + MVs ===
      t.decimal :message_entropy, precision: 8, scale: 4
      t.decimal :unique_message_ratio, precision: 8, scale: 4
      t.decimal :single_message_chatter_ratio, precision: 8, scale: 4
      t.decimal :emote_only_ratio, precision: 8, scale: 4
      t.decimal :avg_inter_message_interval_sec, precision: 10, scale: 3
      t.decimal :timing_regularity_score, precision: 8, scale: 4
      t.decimal :nlp_contextual_relevance_score, precision: 8, scale: 4

      # === Account signals (4) — from ChatterProfile ===
      t.decimal :avg_account_age_days, precision: 10, scale: 2
      t.decimal :account_creation_date_clustering_gini, precision: 8, scale: 4
      t.decimal :profile_completeness_ratio, precision: 8, scale: 4
      t.decimal :engagement_participation_ratio, precision: 8, scale: 4

      # === Growth signals (4) — from FollowerSnapshot ===
      t.decimal :follower_growth_cv_90d, precision: 8, scale: 4
      t.decimal :growth_engagement_correlation, precision: 8, scale: 4
      t.decimal :follow_unfollow_churn_rate, precision: 8, scale: 4
      t.decimal :attributed_spike_ratio, precision: 8, scale: 4

      # === Stability signals (3) — from TrustIndexHistory + chat MVs ===
      t.decimal :trust_index_30d_std, precision: 8, scale: 4
      t.decimal :chat_rate_30d_cv, precision: 8, scale: 4
      t.decimal :viewer_retention_avg_sec, precision: 10, scale: 2

      # === Maturity signals (3) — from Channel + Stream count ===
      t.integer :account_age_days_capped # capped 365 per BFT
      t.integer :total_streams_capped    # capped 200 per BFT
      t.integer :total_hours_capped      # capped 1000 per BFT

      # Optional metadata for ML training pipeline observability
      t.jsonb :extractor_metadata, default: {}, null: false # version-specific notes / per-feature insufficient_data reasons

      t.timestamps precision: 6
    end

    # FK to streams (cascading delete preserves referential integrity on stream removal)
    add_foreign_key :stream_feature_vectors, :streams, on_delete: :cascade

    # Index for ML training window queries (retraining job pulls last N days).
    # CR-247 N3: NO secondary index on stream_id — the composite PK (stream_id, version)
    # already creates a btree with stream_id as leading column; PG can satisfy
    # WHERE stream_id = ? via the PK index. Extra index = write cost without lookup benefit.
    add_index :stream_feature_vectors, :calculated_at
  end

  def down
    remove_index :stream_feature_vectors, :calculated_at
    drop_table :stream_feature_vectors
  end
end
