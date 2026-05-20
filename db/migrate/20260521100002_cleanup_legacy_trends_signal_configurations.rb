# frozen_string_literal: true

# TASK-A1 FR-036 (PO Change Request 2026-05-20): delete 17 orphan SignalConfig
# rows из 5 legacy philosophy-v1 trends.* categories. Services удалены/отсутствуют
# в Trends scope post-philosophy-v2 (DSV probe 6 enumerated 2026-05-20 — no live
# readers).
#
# Scope (5 categories, 17 rows total):
#   1. signal_type='trends' AND category='anomaly_freq' — 5 rows
#      (2 от 20260419100006 + 3 от 20260421100001).
#      Owner = AnomalyFrequencyScorer (philosophy-v1, dropped в Trends v2 scope).
#   2. signal_type='trends' AND category='best_worst' — 1 row
#      (от 20260421100001). Owner = BestWorstStreamFinder (зависел от dropped
#      TDA is_best_stream_day/is_worst_stream_day cols, см. FR-035).
#   3. signal_type='trends' AND category='cache' — 1 row (schema_version=2,
#      от 20260419100006). v2-cache versioning не используется в Trends v2 API
#      cache (per ADR v2.0 — versioned key builder вместо row-stored version).
#   4. signal_type='trends' AND category='coupling' — 4 rows
#      (от 20260421100001). Owner = FollowerCcvCouplingTimeline (philosophy-v1,
#      dropped — Reputation Categorical Badge заменил concept).
#   5. signal_type='trends' AND category='discovery' — 6 rows
#      (от 20260419100006). Owner = DiscoveryPhaseDetector (philosophy-v1,
#      dropped — зависел от TIH percentile snapshots, also removed TASK-201).
#
# def down re-seeds verbatim from original 2 source migrations:
#   - 20260419100006_seed_trends_signal_configurations.rb (anomaly_freq×2, cache, discovery×6)
#   - 20260421100001_seed_trends_analysis_configurations.rb (coupling×4, anomaly_freq×3, best_worst)
#
# Pattern mirrors TASK-201 Phase 3.1 (20260519100009_delete_hs_rehab_signal_config_rows.rb) —
# re-seed verbatim для true reversibility.
#
# NB observed overlap (NOT in FR-036 scope per Scope Freeze): SRS v3.0 Migration 2 seeds
# 4 rows под new naming convention trends.{direction,weekday,categories}.*; existing
# trends.{trend,patterns}.* rows under old naming convention overlap semantically. PO
# Change Request 2026-05-20 explicitly scoped FR-036 к 5 listed categories только; trend
# + patterns cleanup = future Change Request candidate, NOT auto-expanded here.

class CleanupLegacyTrendsSignalConfigurations < ActiveRecord::Migration[8.0]
  LEGACY_CATEGORIES = %w[anomaly_freq best_worst cache coupling discovery].freeze

  def up
    SignalConfiguration
      .where(signal_type: "trends", category: LEGACY_CATEGORIES)
      .delete_all
  end

  def down
    now = Time.current

    # Re-seed from 20260419100006_seed_trends_signal_configurations.rb (verbatim subset).
    seed_from_19100006 = [
      # === AnomalyFrequencyScorer (FR-031, ADR §4.8 philosophy-v1) ===
      [ "trends", "anomaly_freq", "elevated_threshold_pct", 50 ],
      [ "trends", "anomaly_freq", "reduced_threshold_pct", -20 ],

      # === Cache versioning (ADR §4.12 philosophy-v1) ===
      [ "trends", "cache", "schema_version", 2 ],

      # === DiscoveryPhaseDetector (FR-029, ADR §4.5 philosophy-v1) ===
      [ "trends", "discovery", "logistic_r2_organic_min", 0.7 ],
      [ "trends", "discovery", "step_r2_burst_min", 0.9 ],
      [ "trends", "discovery", "burst_window_days_max", 3 ],
      [ "trends", "discovery", "burst_jump_min", 1000 ],
      [ "trends", "discovery", "channel_age_max_days", 60 ],
      [ "trends", "discovery", "min_data_points", 7 ]
    ]

    # Re-seed from 20260421100001_seed_trends_analysis_configurations.rb (verbatim subset).
    seed_from_21100001 = [
      # === FollowerCcvCouplingTimeline (FR-030 philosophy-v1) ===
      [ "trends", "coupling", "rolling_window_days", 30 ],
      [ "trends", "coupling", "healthy_r_min", 0.7 ],
      [ "trends", "coupling", "weakening_r_min", 0.3 ],
      [ "trends", "coupling", "min_history_days", 7 ],

      # === AnomalyFrequencyScorer additional (FR-031 philosophy-v1) ===
      [ "trends", "anomaly_freq", "baseline_lookback_ratio", 1.0 ],
      [ "trends", "anomaly_freq", "min_baseline_streams", 3 ],
      [ "trends", "anomaly_freq", "min_confidence_threshold", 0.4 ],

      # === BestWorstStreamFinder (FR-032 philosophy-v1) ===
      [ "trends", "best_worst", "min_streams_required", 3 ]
    ]

    rows = (seed_from_19100006 + seed_from_21100001).map do |signal_type, category, param_name, param_value|
      {
        signal_type: signal_type,
        category: category,
        param_name: param_name,
        param_value: param_value,
        created_at: now,
        updated_at: now
      }
    end

    # Original migrations использовали on_duplicate: :skip — admin-tuned values
    # preserved при repeated rollback/migrate cycles.
    SignalConfiguration.upsert_all(rows,
      unique_by: %i[signal_type category param_name],
      on_duplicate: :skip)
  end
end
