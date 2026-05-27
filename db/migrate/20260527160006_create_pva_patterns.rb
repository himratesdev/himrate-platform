# frozen_string_literal: true

# TASK-113 BE-1 (FR-010, M11): авто-найденные поведенческие паттерны (actionable insight-cards).
# v1 = RULE-BASED агрегация SyncEvent (ADR Variant A; напр. «+64% будни-вечер» = чистая статистика).
# ML-hook: sentiment_enabled (ONNX rubert) позже добавляет sentiment-инсайты БЕЗ переписывания.
# PatternsWorker (cron) пересчитывает per пользователя.
class CreatePvaPatterns < ActiveRecord::Migration[8.0]
  def up
    create_table :pva_patterns, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :pattern_type, null: false, limit: 30 # rhythm / content / sentiment
      t.string :title, null: false
      t.text :body, null: false
      t.text :actionable                        # «что попробовать» — nullable
      t.decimal :confidence, precision: 4, scale: 2 # 0..1 — nullable
      t.boolean :sentiment_enabled, null: false, default: false # ML-hook
      t.datetime :computed_at, null: false
      t.timestamps
    end

    add_index :pva_patterns, %i[user_id computed_at], name: "idx_pva_patterns_user_time"
  end

  def down
    drop_table :pva_patterns
  end
end
