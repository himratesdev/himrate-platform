# frozen_string_literal: true

# BUG-010 PR3 (ADR DEC-13 corrigendum): pure Ruby heuristic baseline для drift forecast.
# Replaces sklearn pickle artifact (rejected — Ruby/Python boundary too costly для текущего scale).
# Trainer computes mean + stddev интервалов между drift events per pair, persists row здесь.
# Inference reads + emits DriftForecastPrediction rows.
class CreateDriftBaselines < ActiveRecord::Migration[8.1]
  def change
    create_table :drift_baselines, id: :uuid do |t|
      t.string :destination, null: false
      t.string :accessory, null: false
      t.bigint :mean_interval_seconds
      t.bigint :stddev_interval_seconds
      t.integer :sample_count, null: false, default: 0
      t.string :algorithm_version, null: false # e.g. "ruby_heuristic_v1"
      t.datetime :computed_at, null: false
      t.timestamps
    end

    add_index :drift_baselines, %i[destination accessory], unique: true,
              name: "idx_drift_baselines_pair_unique"
  end
end
