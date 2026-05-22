# frozen_string_literal: true

# TASK-A1 FR-035 (PO Change Request 2026-05-20): drop 4 philosophy-v1 orphan
# columns + 2 partial indexes из trends_daily_aggregates (TDA).
#
# Origin (20260419100001): TDA was created with 5 "v2.0 extensions" columns.
# TASK-201 Phase 3.3 already dropped tier_change_on_day (HS-tier dependency).
# Remaining 4 columns reference philosophy-v1 concepts removed by 2026-05-06
# (Discovery Phase Detector, Follower-CCV Coupling Timeline, Best/Worst Stream
# Finder). No live readers/writers post-TASK-201 (DSV probe 4 verified
# 2026-05-20: 0 references in services / workers / aggregations).
#
# Scope (6 schema objects, all on native-partitioned parent — ALTER propagates
# к all partitions automatically per PG 11+):
#   - idx_tda_discovery       (partial WHERE discovery_phase_score IS NOT NULL)
#   - idx_tda_best_worst      (partial WHERE is_best_stream_day = true OR is_worst_stream_day = true)
#   - discovery_phase_score   (decimal(4,3), nullable)
#   - follower_ccv_coupling_r (decimal(4,3), nullable)
#   - is_best_stream_day      (boolean NOT NULL default false)
#   - is_worst_stream_day     (boolean NOT NULL default false)
#
# def down rebuilds 1:1 from 20260419100001 (column types, defaults, partial
# WHERE clauses). NB: cosmetic attnum drift inherent to PG (`add_column` appends
# at tail; no AFTER syntax) — functional behavior identical post-rollback, см.
# TASK-201 Phase 3.3 header для подробного обоснования.

class DropTdaPhilosophyV1OrphanColumns < ActiveRecord::Migration[8.0]
  def up
    # Drop indexes first (must precede referenced columns)
    remove_index :trends_daily_aggregates,
                 name: "idx_tda_discovery",
                 if_exists: true

    remove_index :trends_daily_aggregates,
                 name: "idx_tda_best_worst",
                 if_exists: true

    # Drop columns на native-partitioned parent — propagates to all partitions
    remove_column :trends_daily_aggregates, :discovery_phase_score
    remove_column :trends_daily_aggregates, :follower_ccv_coupling_r
    remove_column :trends_daily_aggregates, :is_best_stream_day
    remove_column :trends_daily_aggregates, :is_worst_stream_day
  end

  def down
    # Restore columns first (verbatim types/defaults from 20260419100001 lines 48-52).
    add_column :trends_daily_aggregates, :discovery_phase_score, :decimal,
      precision: 4, scale: 3
    add_column :trends_daily_aggregates, :follower_ccv_coupling_r, :decimal,
      precision: 4, scale: 3
    add_column :trends_daily_aggregates, :is_best_stream_day, :boolean,
      null: false, default: false
    add_column :trends_daily_aggregates, :is_worst_stream_day, :boolean,
      null: false, default: false

    # Restore partial indexes (verbatim from 20260419100001 lines 81-87).
    add_index :trends_daily_aggregates, %i[channel_id discovery_phase_score],
      where: "discovery_phase_score IS NOT NULL",
      name: "idx_tda_discovery"

    add_index :trends_daily_aggregates, %i[channel_id is_best_stream_day is_worst_stream_day],
      where: "is_best_stream_day = true OR is_worst_stream_day = true",
      name: "idx_tda_best_worst"
  end
end
