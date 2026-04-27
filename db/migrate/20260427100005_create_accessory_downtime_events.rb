# frozen_string_literal: true

# BUG-010 PR2: accessory downtime tracking (dormant pre-launch — revenue_baseline empty).
# Hooks: workflow + worker INSERT on each restart/health_fail/rollback. Source classifies trigger.
# CostAttribution::DowntimeCostCalculator uses these + revenue_baseline for cost estimation.

class CreateAccessoryDowntimeEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :accessory_downtime_events, id: :uuid do |t|
      t.string :destination, null: false
      t.string :accessory, null: false
      t.timestamp :started_at, null: false
      t.timestamp :ended_at
      t.integer :duration_seconds
      t.string :source, null: false  # drift/restart/health_fail/rollback
      t.references :drift_event, type: :uuid, foreign_key: { to_table: :accessory_drift_events }
      t.timestamps
    end

    add_index :accessory_downtime_events,
              [ :destination, :accessory, :started_at ],
              order: { started_at: :desc },
              name: "idx_downtime_events_recent"

    add_check_constraint :accessory_downtime_events,
                         "source IN ('drift', 'restart', 'health_fail', 'rollback')",
                         name: "chk_downtime_source"
  end
end
