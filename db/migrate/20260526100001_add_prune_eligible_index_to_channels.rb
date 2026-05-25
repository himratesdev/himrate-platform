# frozen_string_literal: true

# TASK-251.2: partial index over prune-eligible channels (non-pinned, metadata-synced, but
# display_name still blank = Helix /users returned nothing = banned/deleted). Lets ChannelPruneWorker
# enumerate the prune set in O(eligible) instead of scanning the whole channels table at scale
# (tens of thousands of channels). Pruned rows flip is_monitored=false and drop out of the index.
# Concurrent + separate migration per repo convention (BUG-012).
class AddPruneEligibleIndexToChannels < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :channels, :id,
              where: "is_monitored AND deleted_at IS NULL AND NOT is_pinned AND metadata_synced_at IS NOT NULL AND display_name IS NULL",
              name: "index_channels_prune_eligible",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
