# frozen_string_literal: true

# TASK-038 fix: backfill HealthScore.category from streams.game_name,
# using CategoryMapper.normalize for consistency with new records.
# Worker writes normalized keys (e.g. "just_chatting"), so legacy rows
# must also use normalized keys — otherwise per-category queries miss them.

class NormalizeHealthScoresCategory < ActiveRecord::Migration[8.0]
  # S7: Inline normalization, no dependency on app code (Hs::CategoryMapper).
  # Matches the normalize() logic: lowercase → strip special chars to space →
  # squash spaces to _ → strip trailing/leading _.
  # If Hs::CategoryMapper is renamed later, migration still runs.

  def up
    # Backfill from streams.game_name for NULL categories, inline normalize.
    execute <<~SQL
      UPDATE health_scores hs
      SET category = TRIM(BOTH '_' FROM
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            LOWER(TRIM(s.game_name)),
            '[^a-z0-9]+', '_', 'g'
          ),
          '_+', '_', 'g'
        )
      )
      FROM streams s
      WHERE hs.stream_id = s.id
        AND hs.category IS NULL
        AND s.game_name IS NOT NULL
        AND TRIM(s.game_name) <> '';
    SQL

    # Re-normalize any existing non-null categories.
    execute <<~SQL
      UPDATE health_scores
      SET category = TRIM(BOTH '_' FROM
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            LOWER(TRIM(category)),
            '[^a-z0-9]+', '_', 'g'
          ),
          '_+', '_', 'g'
        )
      )
      WHERE category IS NOT NULL;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
