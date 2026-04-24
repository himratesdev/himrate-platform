# frozen_string_literal: true

# TASK-039 Visual QA: tracking table для idempotent seed/clear of synthetic test data.
# Каждая VQA-seeded channel gets row → re-run safe, teardown complete.
#
# NEVER populated в production (Rails.env.production? guard в seeder services).
# staging/development only.

class CreateVisualQaChannelSeeds < ActiveRecord::Migration[8.0]
  def change
    create_table :visual_qa_channel_seeds, id: :uuid do |t|
      # on_delete: :cascade — удаление Channel автоматически cascade'ит seed row
      # (teardown path не требует manual ordering management).
      t.references :channel, type: :uuid, null: false,
        foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :seed_profile, null: false, limit: 60,
        comment: "Seeder preset (premium_tracked, streamer_with_rehab, etc.)"
      t.datetime :seeded_at, null: false
      t.jsonb :metadata, null: false, default: {},
        comment: "Counts of created rows per kind (streams, tda, tih, anomalies, tier_changes, rehab_events)"
      t.integer :schema_version, null: false, default: 1,
        comment: "Bumped при breaking changes в seed profile structure"
      t.timestamps
    end

    add_index :visual_qa_channel_seeds, :seed_profile
    add_index :visual_qa_channel_seeds, :seeded_at
  end
end
