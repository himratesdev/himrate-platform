# frozen_string_literal: true

# TASK-085 CR N-1 (PR #125): composite index для TiDropDetector cross-stream query.
# TrustIndexHistory.where(channel_id:).where("calculated_at > ?", 30.minutes.ago)
# .order(calculated_at: :desc) executed на каждом signal_compute → critical path.
#
# Existing indexes на отдельные columns (channel_id, calculated_at) — bitmap scan.
# Composite (channel_id, calculated_at) — index scan, ~10x faster под load 1000+ channels.
#
# SRS v1.2 §5.4 already mandates this index — closure of pre-existing infra gap.

class AddTihChannelCalculatedAtIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :trust_index_histories, %i[channel_id calculated_at],
      name: "idx_tih_channel_calc_at",
      algorithm: :concurrently, if_not_exists: true
  end
end
