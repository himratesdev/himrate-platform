# frozen_string_literal: true

# TASK-039 FR-016: Output of attribution pipeline.
# Один anomaly может иметь несколько attributions от разных sources
# (например, raid_organic + platform_cleanup) — UNIQUE (anomaly_id, source).
# Confidence per source. Raw data jsonb для traceability и future re-processing.

class CreateAnomalyAttributions < ActiveRecord::Migration[8.0]
  def change
    create_table :anomaly_attributions, id: :uuid do |t|
      t.references :anomaly, type: :uuid, null: false, foreign_key: true
      t.string :source, limit: 50, null: false # FK-like к attribution_sources.source
      t.decimal :confidence, precision: 5, scale: 4, null: false
      t.jsonb :raw_source_data, default: {}, null: false
      t.datetime :attributed_at, null: false

      t.timestamps
    end

    add_index :anomaly_attributions, %i[anomaly_id source],
      unique: true, name: "idx_anomaly_attr_anomaly_source"

    add_index :anomaly_attributions, :source,
      name: "idx_anomaly_attr_source"

    add_index :anomaly_attributions, %i[anomaly_id confidence],
      order: { confidence: :desc },
      name: "idx_anomaly_attr_anomaly_confidence"
  end
end
