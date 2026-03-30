# frozen_string_literal: true

# TASK-028: 11 Live Signals Calculator.
# 1. Create signal_configurations table for dynamic thresholds + weights (FR-015).
# 2. Add metadata, category, created_at to signals table.
# 3. Add composite index for efficient latest signal lookup.

class CreateSignalConfigurationsAndEnhanceSignals < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    create_table :signal_configurations, id: :uuid do |t|
      t.string :signal_type, limit: 50, null: false
      t.string :category, limit: 50, null: false
      t.string :param_name, limit: 100, null: false
      t.decimal :param_value, precision: 10, scale: 4, null: false

      t.timestamps
    end

    add_index :signal_configurations, %i[signal_type category param_name],
      unique: true, name: "idx_signal_configs_type_category_param"

    # Enhance signals table
    add_column :signals, :metadata, :jsonb, null: false, default: {}
    add_column :signals, :category, :string, limit: 50
    add_column :signals, :created_at, :datetime, null: false, default: -> { "NOW()" }

    add_index :signals, %i[stream_id signal_type timestamp],
      name: "idx_signals_stream_type_timestamp", algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :signals, name: "idx_signals_stream_type_timestamp", if_exists: true
    remove_column :signals, :created_at
    remove_column :signals, :category
    remove_column :signals, :metadata

    drop_table :signal_configurations
  end
end
