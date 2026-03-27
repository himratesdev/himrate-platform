# frozen_string_literal: true

# TASK-016: Composite [stream_id, timestamp] indexes for timeseries queries.
# Without these, WHERE stream_id = ? AND timestamp BETWEEN ? AND ? = full table scan.

class AddTimeseriesIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :ccv_snapshots, %i[stream_id timestamp], name: "idx_ccv_snapshots_stream_time",
      if_not_exists: true
    add_index :chatters_snapshots, %i[stream_id timestamp], name: "idx_chatters_snapshots_stream_time",
      if_not_exists: true
    add_index :chat_messages, %i[stream_id timestamp], name: "idx_chat_messages_stream_time",
      if_not_exists: true
    add_index :erv_estimates, %i[stream_id timestamp], name: "idx_erv_estimates_stream_time",
      if_not_exists: true
    add_index :signals, %i[stream_id timestamp], name: "idx_signals_stream_time",
      if_not_exists: true
    add_index :raid_attributions, %i[stream_id timestamp], name: "idx_raid_attributions_stream_time",
      if_not_exists: true
    add_index :anomalies, %i[stream_id timestamp], name: "idx_anomalies_stream_time",
      if_not_exists: true
  end

  def down
    remove_index :ccv_snapshots, name: "idx_ccv_snapshots_stream_time", if_exists: true
    remove_index :chatters_snapshots, name: "idx_chatters_snapshots_stream_time", if_exists: true
    remove_index :chat_messages, name: "idx_chat_messages_stream_time", if_exists: true
    remove_index :erv_estimates, name: "idx_erv_estimates_stream_time", if_exists: true
    remove_index :signals, name: "idx_signals_stream_time", if_exists: true
    remove_index :raid_attributions, name: "idx_raid_attributions_stream_time", if_exists: true
    remove_index :anomalies, name: "idx_anomalies_stream_time", if_exists: true
  end
end
