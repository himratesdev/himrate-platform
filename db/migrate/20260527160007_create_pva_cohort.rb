# frozen_string_literal: true

# TASK-113 BE-1 (FR-011, M12 «Похожие зрители»): анонимная когорта discovery.
# v1 = CO-WATCH overlap на существующем cross_channel_presence (ADR Variant A; cohort_method='co_watch').
# ML-hook: cohort_method='embedding' (Channel2Vec+Faiss) позже БЕЗ переписывания.
# CohortWorker (cron) пересчитывает; suggestions = анонимные (без PII).
class CreatePvaCohort < ActiveRecord::Migration[8.0]
  def up
    create_table :pva_cohort, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.jsonb :suggestions, null: false, default: [] # [{login, display_name, pct}]
      t.string :cohort_method, null: false, limit: 12, default: "co_watch" # co_watch / embedding
      t.datetime :computed_at, null: false
      t.timestamps
    end

    add_index :pva_cohort, :user_id, unique: true, name: "idx_pva_cohort_unique"
  end

  def down
    drop_table :pva_cohort
  end
end
