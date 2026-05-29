# frozen_string_literal: true

# BUG-251.30: Extend chatters_snapshots with role-bucketed presence counts so AuthRatio
# signal #1 can compute `chatters_present_total / latest_ccv` server-side.
#
# Columns added (all nullable for backward compat — rows from before BUG-251.30 deploy
# simply leave them NULL; AuthRatio falls back to insufficient(:no_chatters_data)):
#   - chatters_present_total INTEGER  — sum across all role buckets
#                                      (= broadcasters + moderators + vips + staff + viewers)
#   - viewer_logins          JSONB    — full role-flattened login array for downstream profile
#                                      enrichment (BotScorer / ChatterProfileRefresh inputs)
#   - broadcasters_count     INTEGER  — role breakdown for analytics / debugging
#   - moderators_count       INTEGER
#   - vips_count             INTEGER
#   - staff_count            INTEGER
#   - viewers_count_present  INTEGER  — distinct from existing unique_chatters_count
#                                      (which counts active-typers from chat_messages)
#
# Naming note: the existing `auth_ratio decimal(8,4)` column (BUG-251.24 precision fix)
# is the ACTIVE-TYPER ratio (chatters who typed / CCV). The new presence-based ratio is
# computed at TI signal time as `chatters_present_total / latest_ccv` and persisted only
# in the TrustIndexHistory.signal_breakdown jsonb (not duplicated as a column here).
#
# Why not concurrent index: no new index added — existing `(stream_id, timestamp)` already
# serves AuthRatio's `latest snapshot per stream` lookup. add_column on the regular
# transaction path is safe for the column-only additions (Rails 8 add_column is fast metadata-only
# even on large tables; defaults/backfills NOT applied here — columns nullable so no rewrite).

class AddChattersPresentColumnsToChattersSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :chatters_snapshots, :chatters_present_total, :integer
    add_column :chatters_snapshots, :viewer_logins, :jsonb
    add_column :chatters_snapshots, :broadcasters_count, :integer
    add_column :chatters_snapshots, :moderators_count, :integer
    add_column :chatters_snapshots, :vips_count, :integer
    add_column :chatters_snapshots, :staff_count, :integer
    add_column :chatters_snapshots, :viewers_count_present, :integer
  end
end
