# frozen_string_literal: true

# TASK-251.12 (hybrid monitoring set): mark curated channels as pinned. Pinned channels are
# guaranteed-monitored and protected from the discovery-cleanup prune (TASK-251.2). Column add is
# transactional; the supporting index ships separately (concurrent) per repo convention (BUG-012).
class AddIsPinnedToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :is_pinned, :boolean, default: false, null: false
  end
end
