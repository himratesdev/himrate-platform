# frozen_string_literal: true

# TASK-201 Phase 3.3: drop dead columns + indexes on live tables (final schema phase).
#
# Scope (8 schema objects):
#   trust_index_histories (TIH) — live snapshot table, only dropping dead columns:
#     - idx_tih_qualifying_snapshots (partial concurrent index, from 20260420100001)
#     - engagement_percentile_at_end                (20260420100001)
#     - engagement_consistency_percentile_at_end    (20260420100001)
#     - category_at_end                             (20260420100001)
#     - rehabilitation_penalty                      (20260330400001)
#     - rehabilitation_bonus                        (20260330400001)
#
#   trends_daily_aggregates (TDA) — native-partitioned parent (PARTITION BY RANGE(date)),
#   dropping dead column + index propagates to all partitions automatically (PG 11+):
#     - idx_tda_tier_change (partial index, from 20260419100001)
#     - tier_change_on_day  (boolean NOT NULL default false, from 20260419100001)
#
# All Rails writers/readers removed in Phase 2.x:
#   - Phase 2.3: TrustIndex::Engine.Result.members removed :rehabilitation_penalty/:rehabilitation_bonus
#               (regression-lock spec in spec/services/trust_index/engine_spec.rb:127-128 stays)
#   - Phase 2.4: Trends::Aggregations::DailyBuilder#tier_change_on_day method removed,
#               TrendsDailyAggregate.with_tier_changes scope removed,
#               MovementInsights tier_change kwarg + constant removed
#   - Phase 2.5: Trends::QualifyingPercentileSnapshotWorker deleted (sole writer of
#               engagement_*_percentile_at_end + category_at_end), Hs::ComponentPercentileService +
#               Reputation::ComponentPercentileService deleted
#
# Inline orphan-ref fixes (would crash post-drop, separate files in same PR):
#   - app/services/trends/visual_qa/tih_history_seeder.rb: remove 2 lines writing
#     rehabilitation_penalty/bonus = 0.0 (Architect Phase 0 missed coverage)
#   - spec/factories/trust_index_histories.rb: remove 2 factory default lines
#     (would break all specs using :trust_index_history factory)
#
# Uses disable_ddl_transaction! для CONCURRENTLY index operations (drop & rebuild).
#
# def down rebuilds final schema 1:1 from original migrations (verified column types,
# defaults, partial WHERE clauses, partial-index WHERE clauses).
#
# NB: Inherent cosmetic drift in `db/structure.sql` post-rollback:
#   PostgreSQL stores columns in `pg_attribute` by `attnum` (creation order).
#   `add_column` always appends at the next available attnum — there is no
#   `ALTER TABLE ... ADD COLUMN ... AFTER <col>` syntax in PostgreSQL (unlike MySQL).
#   On a live table (no DROP+CREATE), restored columns end up at attnum tail,
#   not at their original logical position. Functional behavior identical
#   (correct types, defaults, indexes, FKs); pg_dump output differs by ~20 lines
#   in column position only. Acceptable per Phase 3.1/3.2 CR lesson: byte-identical
#   schema reconstruction was achievable only when the entire table was dropped
#   (streamer_ratings) или constraint added (hs_classification_5tier). For column-only
#   drops on live tables this drift is structural to PostgreSQL.
#
# def down preserves the relative alphabetical order WHERE add_column allows
# (e.g. rehabilitation_bonus before rehabilitation_penalty matches original pg_dump).

class DropTihRehabColumnsAndA3a < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # === Indexes first (must drop before referenced columns) ===

    remove_index :trust_index_histories,
                 name: "idx_tih_qualifying_snapshots",
                 algorithm: :concurrently,
                 if_exists: true

    remove_index :trends_daily_aggregates,
                 name: "idx_tda_tier_change",
                 if_exists: true

    # === TIH columns ===
    # bulk: true → single ALTER TABLE statement (more efficient than 5 separate ALTERs)

    change_table :trust_index_histories, bulk: true do |t|
      t.remove :engagement_percentile_at_end
      t.remove :engagement_consistency_percentile_at_end
      t.remove :category_at_end
      t.remove :rehabilitation_penalty
      t.remove :rehabilitation_bonus
    end

    # === TDA column (native-partitioned: ALTER on parent propagates to all partitions) ===

    remove_column :trends_daily_aggregates, :tier_change_on_day
  end

  def down
    # === TDA column first (lower-level dependency) ===
    # Restores 20260419100001 column: boolean NOT NULL DEFAULT false.
    # PG 11+ propagates to all partitions automatically.

    add_column :trends_daily_aggregates, :tier_change_on_day, :boolean,
      null: false, default: false

    add_index :trends_daily_aggregates, %i[channel_id tier_change_on_day],
      where: "tier_change_on_day = true",
      name: "idx_tda_tier_change"

    # === TIH columns + index ===
    # Restores 20260330400001 (rehabilitation_*) + 20260420100001 (A3a +3 columns + concurrent index).

    # Rehab columns: bonus before penalty to match original pre-drop pg_dump order
    # (project's structure.sql emits the first-section columns alphabetically;
    # both restored columns now land at attnum tail — see header comment).
    # Engagement + category cols: Ruby source order matches 20260420100001 A3a.
    change_table :trust_index_histories, bulk: true do |t|
      t.decimal :rehabilitation_bonus, precision: 5, scale: 2, default: 0
      t.decimal :rehabilitation_penalty, precision: 5, scale: 2, default: 0
      t.decimal :engagement_percentile_at_end, precision: 5, scale: 2
      t.decimal :engagement_consistency_percentile_at_end, precision: 5, scale: 2
      t.string :category_at_end, limit: 100
    end

    add_index :trust_index_histories,
              %i[channel_id engagement_percentile_at_end engagement_consistency_percentile_at_end],
              where: "engagement_percentile_at_end IS NOT NULL AND engagement_consistency_percentile_at_end IS NOT NULL",
              name: "idx_tih_qualifying_snapshots",
              algorithm: :concurrently
  end
end
