# frozen_string_literal: true

# T1-057 MIG-1: add `source` provenance to cross_channel_presences and widen the unique key to
# include it, so live edges (this task) and future VOD-backfill edges (T1-058) coexist as separate
# rows instead of silently overwriting one another on upsert.
#
# The table is EMPTY at migration time (0 writers prior to T1-057 — the edge-ledger had no producer;
# CrossChannelIntelligenceWorker becomes the first), so the column add + index swap are instant and
# need no backfill. Concurrent index ops are used anyway for forward-safety once it carries data.
#
# Reads by (username, channel_id) remain index-served (prefix of the new composite unique key).
class AddSourceToCrossChannelPresences < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  OLD_INDEX = "idx_cross_channel_user_channel"
  NEW_INDEX = "idx_cross_channel_user_channel_source"

  def up
    add_column :cross_channel_presences, :source, :string, limit: 32, null: false, default: "live", if_not_exists: true

    remove_index :cross_channel_presences, name: OLD_INDEX, if_exists: true
    add_index :cross_channel_presences, %i[username channel_id source],
      unique: true, name: NEW_INDEX, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :cross_channel_presences, name: NEW_INDEX, if_exists: true
    add_index :cross_channel_presences, %i[username channel_id],
      unique: true, name: OLD_INDEX, algorithm: :concurrently, if_not_exists: true
    remove_column :cross_channel_presences, :source, if_exists: true
  end
end
