# frozen_string_literal: true

# TASK-038 fix: backfill HealthScore.category from streams.game_name,
# using CategoryMapper.normalize for consistency with new records.
# Worker writes normalized keys (e.g. "just_chatting"), so legacy rows
# must also use normalized keys — otherwise per-category queries miss them.

class NormalizeHealthScoresCategory < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  BATCH_SIZE = 1000

  def up
    total = 0
    updated = 0

    # Backfill from streams.game_name (normalized) for any NULL category
    HealthScore.where(category: nil).includes(:stream).find_each(batch_size: BATCH_SIZE) do |hs|
      total += 1
      raw_name = hs.stream&.game_name
      next if raw_name.blank?

      normalized = Hs::CategoryMapper.normalize(raw_name)
      hs.update_columns(category: normalized) if normalized.present?
      updated += 1
    end

    # Re-normalize any existing non-null categories that aren't already normalized
    HealthScore.where.not(category: nil).find_each(batch_size: BATCH_SIZE) do |hs|
      normalized = Hs::CategoryMapper.normalize(hs.category)
      next if normalized == hs.category || normalized.blank?

      hs.update_columns(category: normalized)
    end

    say "NormalizeHealthScoresCategory: scanned #{total}, backfilled #{updated}"
  end

  def down
    # Irreversible data transformation
    raise ActiveRecord::IrreversibleMigration
  end
end
