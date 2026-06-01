# frozen_string_literal: true

# PR 1e-B (TASK-251.14): Drop chat_messages PG table — reclaim ~11 GB on staging VPS.
#
# Post PR 1e-A (commit 5f572a8, 2026-05-31 05:49Z), all readers + writers migrated to
# ClickHouse (`himrate.chat_messages` in CH cluster). Dual-write was disabled, ChatMessageWorker
# now writes exclusively to CH. Sufficient 24h+ stability verified before this migration
# (gate cleared 2026-06-01 05:49Z, this PR ran +8.5h past anniversary).
#
# The cleanup-drift acknowledgement (~145k row PG↔CH divergence during the 36h backfill
# window when PG CleanupWorker continued retention deletes) is documented in the EPIC
# BUG-251.28 closure body in Notion + PO-side workspace ADR addendum draft. Direction is
# favorable (CH has MORE data than PG at any point); PR 1e-B makes the divergence moot.
#
# Reversibility: `down` reconstructs the table with all columns + 8 indexes + FK exactly
# as they existed on staging at deploy time (captured from `\d chat_messages` 2026-06-01;
# index count = 7 explicit `add_index` calls + 1 implicit from `t.references :stream`).
# Data restoration not in scope — rollback would re-create the empty table; row content
# remains in ClickHouse (single source of truth post-cutover).
class DropChatMessagesTable < ActiveRecord::Migration[8.1]
  def up
    drop_table :chat_messages
  end

  def down
    create_table :chat_messages, id: :uuid do |t|
      t.references :stream, type: :uuid, foreign_key: true
      t.string :username, limit: 255, null: false
      t.text :message_text
      t.datetime :timestamp, precision: 6, null: false
      t.string :subscriber_status, limit: 10
      t.boolean :is_first_msg, null: false, default: false
      t.string :user_type, limit: 10
      t.integer :bits_used, default: 0
      t.decimal :entropy, precision: 8, scale: 4
      t.string :channel_login, limit: 255, null: false
      t.string :msg_type, limit: 20, null: false, default: "privmsg"
      t.string :display_name, limit: 255
      t.string :badge_info, limit: 255
      t.boolean :returning_chatter, null: false, default: false
      t.boolean :vip, null: false, default: false
      t.string :color, limit: 7
      t.text :emotes
      t.string :twitch_msg_id, limit: 255
      t.jsonb :raw_tags, null: false, default: {}
    end

    add_index :chat_messages, :channel_login, name: "idx_chat_messages_channel_login"
    add_index :chat_messages, [ :channel_login, :timestamp ], name: "idx_chat_messages_channel_time"
    add_index :chat_messages, :msg_type, name: "idx_chat_messages_msg_type"
    add_index :chat_messages, [ :stream_id, :timestamp ], name: "idx_chat_messages_stream_time"
    add_index :chat_messages, [ :stream_id, :username ], name: "idx_chat_messages_stream_username"
    add_index :chat_messages, :timestamp
    add_index :chat_messages, :username
  end
end
