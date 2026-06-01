# frozen_string_literal: true

# PR 1e-B (TASK-251.14) follow-up: the historical migration
# 20260512100001_seed_cleanup_retention_thresholds seeded a SignalConfiguration row
# for ("cleanup", "chat_messages", "retention_days", 90). Now that the chat_messages
# PG table is dropped and the TABLE_MAP entry removed from lib/tasks/cleanup.rake,
# the row is orphan dead config. Cleanly remove it.
#
# Reversibility: down side recreates the row with the same default value (90) so
# rollback alongside the parent drop_table migration produces a coherent state.
class RemoveOrphanChatMessagesRetentionConfig < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL)
      DELETE FROM signal_configurations
      WHERE signal_type = 'cleanup'
        AND category = 'chat_messages'
        AND param_name = 'retention_days'
    SQL
  end

  def down
    execute(<<~SQL)
      INSERT INTO signal_configurations (id, signal_type, category, param_name, param_value, created_at, updated_at)
      VALUES (gen_random_uuid(), 'cleanup', 'chat_messages', 'retention_days', 90, NOW(), NOW())
      ON CONFLICT (signal_type, category, param_name) DO NOTHING
    SQL
  end
end
