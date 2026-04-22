# frozen_string_literal: true

# TASK-039 Phase C2 CR S-2: GIN index на trends_daily_aggregates.categories jsonb.
#
# Мотивация: PeerComparisonService + CategoryPattern делают jsonb_exists(categories, ?)
# scans при каждом первом cache miss. При 100k+ каналов × 30 дней = 3M+ rows →
# без index sequential scan > 5s (SRS §8.1 p95).
#
# jsonb_path_ops operator class — optimized для ? operator (existence check).
# Меньше размер index vs default jsonb_ops.
#
# Partitioned table: PG НЕ поддерживает CREATE INDEX CONCURRENTLY на partitioned
# parent (as of PG 17). Standard CREATE INDEX на parent автоматически пропагируется
# на каждую partition (PG 11+). Берёт ShareLock на parent, AccessExclusiveLock на
# каждую partition (по одной за раз) — для staging/MVP acceptable, т.к. TDA partitions
# относительно небольшие (monthly).
#
# Для production-level zero-lock alternative:
#   1. ALTER TABLE ... DETACH PARTITION каждую
#   2. CREATE INDEX CONCURRENTLY на каждую detached partition
#   3. ALTER TABLE ... ATTACH PARTITION обратно
# Phase E optimization — follow-up через TASK-071-style тех-дебт ticket когда
# партиции реально станут тяжёлыми.

class AddCategoriesGinIndex < ActiveRecord::Migration[8.0]
  def up
    return if index_exists?

    execute(<<~SQL)
      CREATE INDEX idx_tda_categories_gin
        ON trends_daily_aggregates
        USING GIN (categories jsonb_path_ops);
    SQL
  end

  def down
    return unless index_exists?

    execute("DROP INDEX IF EXISTS idx_tda_categories_gin;")
  end

  private

  def index_exists?
    ActiveRecord::Base.connection.select_value(
      "SELECT 1 FROM pg_indexes WHERE indexname = 'idx_tda_categories_gin' AND tablename = 'trends_daily_aggregates'"
    ).present?
  end
end
