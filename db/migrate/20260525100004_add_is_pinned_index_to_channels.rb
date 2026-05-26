# frozen_string_literal: true

# TASK-251.12: partial index over pinned channels (the small curated set). Serves "list pinned"
# lookups (seeder verification, admin) and the TASK-251.2 prune's "exclude pinned" protection.
# Concurrent + separate migration (channels is large at prod scale) per repo convention (BUG-012).
class AddIsPinnedIndexToChannels < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :channels, :is_pinned,
              where: "is_pinned",
              name: "index_channels_on_is_pinned_true",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
