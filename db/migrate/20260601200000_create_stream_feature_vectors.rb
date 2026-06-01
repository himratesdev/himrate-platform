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
#
# CR-247 iter-4 (CI test failure): Rails 8.0 `primary_key: [:a, :b]` shortcut in
# create_table does NOT emit a real PG-level composite PK constraint (silent no-op).
# Migrated to explicit `execute(<<~SQL)` pattern — same as
# `db/migrate/20260528180001_create_pva_chat_activities.rb` (PVA Chat Activities) +
# `20260527170002_create_pva_view_rollup.rb` (PVA View Rollup) which both use raw SQL
# `PRIMARY KEY (id, date)` for composite-PK enforcement. Project uses
# `config.active_record.schema_format = :sql` so structure.sql round-trips the explicit
# constraint correctly.
class CreateStreamFeatureVectors < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE stream_feature_vectors (
        stream_id uuid NOT NULL,
        version integer NOT NULL DEFAULT 1,
        calculated_at timestamp(6) without time zone NOT NULL,

        -- === Viewer signals (4) — from CcvSnapshot + ChattersSnapshot ===
        chatter_to_ccv_ratio numeric(8, 4),
        peak_to_average_ccv_ratio numeric(8, 4),
        ccv_coefficient_of_variation numeric(8, 4),
        ccv_tier_stickiness numeric(8, 4),

        -- === Chat signals (7) — from ClickHouse chat_messages + MVs ===
        message_entropy numeric(8, 4),
        unique_message_ratio numeric(8, 4),
        single_message_chatter_ratio numeric(8, 4),
        emote_only_ratio numeric(8, 4),
        avg_inter_message_interval_sec numeric(10, 3),
        timing_regularity_score numeric(8, 4),
        nlp_contextual_relevance_score numeric(8, 4),

        -- === Account signals (4) — from ChatterProfile ===
        avg_account_age_days numeric(10, 2),
        account_creation_date_clustering_gini numeric(8, 4),
        profile_completeness_ratio numeric(8, 4),
        engagement_participation_ratio numeric(8, 4),

        -- === Growth signals (4) — from FollowerSnapshot ===
        follower_growth_cv_90d numeric(8, 4),
        growth_engagement_correlation numeric(8, 4),
        follow_unfollow_churn_rate numeric(8, 4),
        attributed_spike_ratio numeric(8, 4),

        -- === Stability signals (3) — from TrustIndexHistory + chat MVs ===
        trust_index_30d_std numeric(8, 4),
        chat_rate_30d_cv numeric(8, 4),
        viewer_retention_avg_sec numeric(10, 2),

        -- === Maturity signals (3) — from Channel + Stream count ===
        account_age_days_capped integer,
        total_streams_capped integer,
        total_hours_capped integer,

        extractor_metadata jsonb NOT NULL DEFAULT '{}',

        created_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(6) without time zone NOT NULL DEFAULT now(),

        PRIMARY KEY (stream_id, version),
        FOREIGN KEY (stream_id) REFERENCES streams(id) ON DELETE CASCADE
      );
    SQL

    # Index for ML training window queries (retraining job pulls last N days).
    # CR-247 N3: NO secondary index on stream_id — the composite PK (stream_id, version)
    # already creates a btree with stream_id as leading column; PG can satisfy
    # WHERE stream_id = ? via the PK index. Extra index = write cost without lookup benefit.
    add_index :stream_feature_vectors, :calculated_at
  end

  def down
    drop_table :stream_feature_vectors
  end
end
