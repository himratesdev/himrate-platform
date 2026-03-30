# frozen_string_literal: true

# TASK-026: Enhance known_bot_lists for multi-source + bot categorization.
# 1. Replace unique(username) → composite [username, source] for multi-source cross-reference
# 2. Add bot_category (view_bot/service_bot/unknown) — Nightbot ≠ view-bot
# 3. Add last_seen_at — track when bot was last seen in a real chat
# Table is empty — zero risk.

class EnhanceKnownBotLists < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # Replace unique index: username → [username, source]
    remove_index :known_bot_lists, :username, if_exists: true
    add_index :known_bot_lists, %i[username source], unique: true,
      name: "idx_known_bot_lists_username_source", algorithm: :concurrently, if_not_exists: true
    add_index :known_bot_lists, :source, name: "idx_known_bot_lists_source",
      algorithm: :concurrently, if_not_exists: true

    # New columns
    add_column :known_bot_lists, :bot_category, :string, limit: 20, null: false, default: "unknown"
    add_column :known_bot_lists, :last_seen_at, :datetime
  end

  def down
    remove_column :known_bot_lists, :last_seen_at
    remove_column :known_bot_lists, :bot_category

    remove_index :known_bot_lists, name: "idx_known_bot_lists_source", if_exists: true
    remove_index :known_bot_lists, name: "idx_known_bot_lists_username_source", if_exists: true
    add_index :known_bot_lists, :username, unique: true, if_not_exists: true
  end
end
