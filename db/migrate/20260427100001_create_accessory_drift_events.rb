# frozen_string_literal: true

# BUG-010 PR2: drift events table — auto-detection records by AccessoryDriftDetectorWorker.
# One open event per (destination, accessory) at a time (partial unique index).
# resolved_at populated when worker detects match (declared == runtime).

class CreateAccessoryDriftEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :accessory_drift_events, id: :uuid do |t|
      t.string :destination, null: false
      t.string :accessory, null: false
      t.string :declared_image, null: false
      t.string :runtime_image, null: false
      t.timestamp :detected_at, null: false
      t.timestamp :resolved_at
      t.string :status, null: false, default: "open"
      t.timestamp :alert_sent_at
      t.timestamps
    end

    # Idempotency lookup: at most one open event per (destination, accessory).
    add_index :accessory_drift_events,
              [ :destination, :accessory ],
              unique: true,
              where: "status = 'open'",
              name: "idx_drift_events_open_unique"

    # Timeline queries for dashboards.
    add_index :accessory_drift_events, :detected_at, order: { detected_at: :desc }

    add_check_constraint :accessory_drift_events,
                         "status IN ('open', 'resolved')",
                         name: "chk_drift_events_status"
  end
end
