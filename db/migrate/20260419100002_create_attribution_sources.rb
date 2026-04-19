# frozen_string_literal: true

# TASK-039 FR-016 + ADR §4.14: DB-driven config для anomaly attribution adapters.
# Build-for-years: future adapters (IGDB, Helix, Twitter, Viral Clip) — это
# disabled rows + adapter class. Включить = UPDATE enabled=true. Без миграций.

class CreateAttributionSources < ActiveRecord::Migration[8.0]
  def change
    create_table :attribution_sources, id: :uuid do |t|
      t.string :source, limit: 50, null: false
      t.boolean :enabled, null: false, default: false
      t.integer :priority, null: false, default: 999 # ASC: ниже = выше приоритет
      t.string :adapter_class_name, limit: 100, null: false
      t.string :display_label_en, limit: 100, null: false
      t.string :display_label_ru, limit: 100, null: false
      t.jsonb :metadata, default: {}, null: false # adapter-specific config

      t.timestamps
    end

    add_index :attribution_sources, :source, unique: true,
      name: "idx_attr_sources_source"

    add_index :attribution_sources, %i[enabled priority],
      where: "enabled = true",
      name: "idx_attr_sources_enabled_priority"
  end
end
