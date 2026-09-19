# frozen_string_literal: true

# DETECTION-AUDIT 2026-09-19 (PIPELINE-HEALTH #26). erv_estimates is a v1 artefact with no writer
# and no reader: the last row was written 2026-08-27, ERV has lived on
# trust_index_histories.erv since the v2 cutover, and the one place that still mentions the table
# (ErvDivergenceDetector) exists to say it IGNORES it. Every consumer was traced before dropping —
# model, Stream association, blueprints, rake, retention (CleanupWorker does not manage it), API
# payloads and factories: nothing reads or writes it, so the table is removed with its model and
# association rather than left as a trap for the next person who greps «erv».
#
# Reversible: `down` restores the exact structure + index, so the drop is not a one-way door. The
# 0 rows it holds are not restored — there are none.
#
# NOT dropped, deliberately: the `signals` (TiSignal) table is equally dead-write, but CleanupWorker
# still runs its retention branch and weekly row-stats gauge against it and SignalConfiguration
# carries its retention row — it has live consumers, so it needs its own decision, not a drive-by.
class DropTheOrphanedErvEstimatesTable < ActiveRecord::Migration[8.0]
  def up
    drop_table :erv_estimates, if_exists: true
  end

  def down
    create_table :erv_estimates, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.datetime :timestamp, null: false
      t.integer :erv_count, null: false
      t.decimal :erv_percent, precision: 5, scale: 2, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.string :label, limit: 30
    end
    add_index :erv_estimates, %i[stream_id timestamp], name: "idx_erv_estimates_stream_time"
  end
end
