# frozen_string_literal: true

# TASK-027: Add classification column + indexes for bot scoring engine.
# per_user_bot_scores already exists (TASK-003). Adding:
# - classification: 5-tier label (human/low_suspicion/suspicious/probable_bot/confirmed_bot)
# - UNIQUE index (stream_id, username): for upsert during batch scoring
# - Index (stream_id, classification): for aggregation queries
# - Index on chat_messages(stream_id, username): for per-user aggregation (Architect recommendation)

class AddClassificationToPerUserBotScores < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_column :per_user_bot_scores, :classification, :string, limit: 20, null: false, default: "unknown"

    add_index :per_user_bot_scores, %i[stream_id username],
      unique: true, name: "idx_bot_scores_stream_username", algorithm: :concurrently, if_not_exists: true
    add_index :per_user_bot_scores, %i[stream_id classification],
      name: "idx_bot_scores_stream_classification", algorithm: :concurrently, if_not_exists: true
    add_index :chat_messages, %i[stream_id username],
      name: "idx_chat_messages_stream_username", algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :chat_messages, name: "idx_chat_messages_stream_username", if_exists: true
    remove_index :per_user_bot_scores, name: "idx_bot_scores_stream_classification", if_exists: true
    remove_index :per_user_bot_scores, name: "idx_bot_scores_stream_username", if_exists: true
    remove_column :per_user_bot_scores, :classification
  end
end
