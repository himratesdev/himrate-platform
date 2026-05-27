# frozen_string_literal: true

# TASK-113 BE-1 (FR-009, M10): weekly «резюме недели» (retention-движок).
# v1 = TEMPLATE-нарратив из агрегатов (ADR Variant A; reflection_source='template').
# ML-hook: reflection_source='llm' позже (отдельный ML-таск) БЕЗ переписывания схемы.
# WeeklyReflectionWorker (cron вс) генерирует per активного пользователя.
class CreatePvaWeeklyReflections < ActiveRecord::Migration[8.0]
  def up
    create_table :pva_weekly_reflections, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.date :week_start, null: false
      t.text :narrative, null: false
      t.jsonb :moments, null: false, default: [] # [{icon, text}] «moments worth noting»
      t.string :reflection_source, null: false, limit: 12, default: "template" # template / llm
      t.datetime :generated_at, null: false
      t.timestamps
    end

    add_index :pva_weekly_reflections, %i[user_id week_start], unique: true,
      name: "idx_pva_reflection_unique"
  end

  def down
    drop_table :pva_weekly_reflections
  end
end
