# frozen_string_literal: true

# BUG-010 PR2: accessory state DB table (replaces FR-022 file pattern per ADR DEC-23).
# Tracks current_image + previous_image для rollback target. Queryable, backed by DB backup.
# File cache fallback (StateCacheService) handles DB-down rollback edge case.

class CreateAccessoryState < ActiveRecord::Migration[8.0]
  def change
    create_table :accessory_states, id: :uuid do |t|
      t.string :destination, null: false
      t.string :accessory, null: false
      t.string :current_image, null: false
      t.string :previous_image
      t.timestamp :last_health_check_at
      t.string :last_health_status
      t.timestamps
    end

    add_index :accessory_states, [ :destination, :accessory ], unique: true,
              name: "idx_accessory_states_unique"
  end
end
