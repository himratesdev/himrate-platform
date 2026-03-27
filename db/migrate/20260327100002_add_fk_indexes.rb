# frozen_string_literal: true

# TASK-016: Missing FK indexes on hot tables.
# Without these, JOINs and WHERE on FK columns = sequential scan.

class AddFkIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :trust_index_histories, :channel_id, name: "idx_ti_histories_channel",
      if_not_exists: true
    add_index :health_scores, :channel_id, name: "idx_health_scores_channel",
      if_not_exists: true
    add_index :per_user_bot_scores, :stream_id, name: "idx_per_user_bot_scores_stream",
      if_not_exists: true
    add_index :notifications, :user_id, name: "idx_notifications_user",
      if_not_exists: true
    add_index :watchlists, :user_id, name: "idx_watchlists_user",
      if_not_exists: true
    add_index :score_disputes, %i[user_id submitted_at], name: "idx_score_disputes_user_submitted",
      if_not_exists: true
    add_index :sessions, %i[user_id is_active], name: "idx_sessions_user_active",
      if_not_exists: true
  end

  def down
    remove_index :trust_index_histories, name: "idx_ti_histories_channel", if_exists: true
    remove_index :health_scores, name: "idx_health_scores_channel", if_exists: true
    remove_index :per_user_bot_scores, name: "idx_per_user_bot_scores_stream", if_exists: true
    remove_index :notifications, name: "idx_notifications_user", if_exists: true
    remove_index :watchlists, name: "idx_watchlists_user", if_exists: true
    remove_index :score_disputes, name: "idx_score_disputes_user_submitted", if_exists: true
    remove_index :sessions, name: "idx_sessions_user_active", if_exists: true
  end
end
