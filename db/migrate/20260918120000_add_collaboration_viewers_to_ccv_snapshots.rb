# frozen_string_literal: true

# WS2 (Hermes realtime viewcount): Twitch's video-playback-by-id push carries an undocumented
# costream split — `collaboration_viewers` (combined onlookers across a shared-chat/costream)
# distinct from this channel's solo `viewers`, plus `collaboration_status` (none/in_collaboration).
# Additive + nullable: only bin/hermes_monitor populates these; the 60s polling path leaves them
# NULL. No read-path change — existing TI/ERV read `ccv_count` only.
class AddCollaborationViewersToCcvSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :ccv_snapshots, :collaboration_viewers, :integer, null: true
    add_column :ccv_snapshots, :collaboration_status, :string, null: true
  end
end
