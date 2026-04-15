# frozen_string_literal: true

# TASK-037 FR-022/Architect: Drop unique index → non-unique for reputation history (create! not find_or_initialize).
class FixStreamerReputationsIndexForHistory < ActiveRecord::Migration[8.0]
  def up
    remove_index :streamer_reputations, column: :channel_id, name: "index_streamer_reputations_on_channel_id"
    add_index :streamer_reputations, :channel_id, name: "idx_streamer_reputations_channel"
    add_index :streamer_reputations, %i[channel_id calculated_at], order: { calculated_at: :desc },
      name: "idx_streamer_reputations_channel_latest"
  end

  def down
    remove_index :streamer_reputations, name: "idx_streamer_reputations_channel_latest"
    remove_index :streamer_reputations, name: "idx_streamer_reputations_channel"
    add_index :streamer_reputations, :channel_id, unique: true, name: "index_streamer_reputations_on_channel_id"
  end
end
