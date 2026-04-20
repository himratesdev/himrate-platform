# frozen_string_literal: true

# TASK-039 Phase A3a (FR-046 foundation): Per-stream snapshot of qualifying
# percentiles taken AT STREAM END.
#
# Why per-stream snapshot (not channel-current-state):
#   Bonus accelerator (FR-046) classifies CLEAN STREAMS individually as
#   "qualifying" if both percentiles ≥ threshold AT THE TIME OF THAT STREAM.
#   Channel-current-state percentile would conflate post-rehab improvements
#   into pre-rehab streams, inflating bonus incorrectly.
#
# Sources:
#   - engagement_percentile_at_end       ← Hs::ComponentPercentileService :engagement
#                                          (formula chat_msg/min/CCV × 1000 — semantically chatter_to_ccv)
#   - engagement_consistency_percentile_at_end ← Reputation::ComponentPercentileService :engagement_consistency
#                                                (NEW service, reads streamer_reputations table)
#   - category_at_end ← stream.game_name → Hs::CategoryMapper.map (category for percentile context)
#
# Backfill: rake trends:backfill_qualifying_percentiles
class AddQualifyingPercentileSnapshotsToTrustIndexHistories < ActiveRecord::Migration[8.0]
  # PG W-1 fix: CONCURRENTLY index требует disable_ddl_transaction! — non-blocking
  # build для existing trust_index_histories rows (table grows per stream, может
  # быть large на production scale 100k+ channels). add_column nullable без
  # DEFAULT в PG 11+ = metadata-only instant — safe outside transaction.
  disable_ddl_transaction!

  def up
    add_column :trust_index_histories, :engagement_percentile_at_end, :decimal, precision: 5, scale: 2
    add_column :trust_index_histories, :engagement_consistency_percentile_at_end, :decimal, precision: 5, scale: 2
    add_column :trust_index_histories, :category_at_end, :string, limit: 100

    # Partial index: только rows со snapshots (skips legacy/uncomputed). Used by
    # BonusAcceleratorCalculator (Phase A3b) для qualifying count query per channel.
    # CONCURRENTLY = non-blocking build (lock minimum, allows reads/writes during build).
    add_index :trust_index_histories,
              %i[channel_id engagement_percentile_at_end engagement_consistency_percentile_at_end],
              where: "engagement_percentile_at_end IS NOT NULL AND engagement_consistency_percentile_at_end IS NOT NULL",
              name: "idx_tih_qualifying_snapshots",
              algorithm: :concurrently
  end

  def down
    remove_index :trust_index_histories,
                 name: "idx_tih_qualifying_snapshots",
                 algorithm: :concurrently
    remove_column :trust_index_histories, :category_at_end
    remove_column :trust_index_histories, :engagement_consistency_percentile_at_end
    remove_column :trust_index_histories, :engagement_percentile_at_end
  end
end
