# frozen_string_literal: true

# TASK-110 FR-024..025: Dark-period markers (когда user смотрел Twitch без extension).
# Computed by TASK-187 separate worker (T1 backend stream) — TASK-110 ships table + reader endpoint
# (GET /sync/snapshot.dark_period_markers[]). Banner UX в S3 sync settings tab.
class CreateDarkPeriodMarkers < ActiveRecord::Migration[8.0]
  def change
    create_table :dark_period_markers, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.datetime :period_start, null: false
      t.datetime :period_end
      t.integer :n_streams, null: false, default: 0
      t.integer :m_channels, null: false, default: 0
      t.datetime :last_extension_seen_at

      t.timestamps
    end

    add_index :dark_period_markers, %i[user_id period_start], order: { period_start: :desc }
  end
end
