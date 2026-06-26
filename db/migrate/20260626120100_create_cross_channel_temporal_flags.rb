# frozen_string_literal: true

# T1-057 MIG-2: per-user-GLOBAL temporal cross-channel bot flags (FR-B).
#
# A user posting in >=3 distinct channels inside a sliding <=W-second window forms a co-occurrence
# event; event_count (R) is how many recur over rolling 24h. Tier escalates with R. This is a
# DIFFERENT grain from per_user_bot_scores (per-stream) — temporal co-occurrence is cross-stream, so
# it gets its own bounded table keyed by username (mirrors cross_channel_digests). Only R>=2 rows
# are written (bounded output); pruned by refreshed_at on the rolling window.
class CreateCrossChannelTemporalFlags < ActiveRecord::Migration[8.1]
  def up
    create_table :cross_channel_temporal_flags, id: false, primary_key: :username do |t|
      t.text :username, null: false, primary_key: true
      t.integer :event_count, null: false              # R — recurrence count of >=3-channel events
      t.integer :max_concurrent_channels, null: false  # max distinct channels in any W-window (mc)
      t.string :bot_flag_tier, limit: 16, null: false  # watch / flag / yellow / confirmed
      t.string :bot_type, limit: 16, null: false       # utility (allowlist) / spam / unknown
      t.integer :window_seconds, null: false, default: 5
      t.datetime :last_event_at
      t.datetime :refreshed_at, null: false
    end

    # Refresh-cycle prune (refreshed_at < now-25h) + TI read filters by tier.
    add_index :cross_channel_temporal_flags, :refreshed_at, name: "idx_cc_temporal_flags_refreshed_at"
    add_index :cross_channel_temporal_flags, :bot_flag_tier, name: "idx_cc_temporal_flags_tier"
  end

  def down
    drop_table :cross_channel_temporal_flags
  end
end
