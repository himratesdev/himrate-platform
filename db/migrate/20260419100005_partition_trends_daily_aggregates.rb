# frozen_string_literal: true

# TASK-039 ADR §4.2: pg_partman monthly partitions для trends_daily_aggregates.
# 100k channels × 365d = 36.5M rows/year, 5y = 180M+. Per-partition ~3M rows.
# Retention 2 years (drop старых партиций мгновенно vs months DELETE).
#
# В production pg_partman extension ОБЯЗАТЕЛЕН — миграция raise если недоступен
# (иначе таблица разрастётся до 50M+ rows без партиционирования незаметно для ops).
# В dev/test — skip с warning (extension не всегда установлен локально).
# Down migration marked irreversible — pg_partman undo_partition может создать
# divergent state, manual rollback required (см. комментарий в def down).

class PartitionTrendsDailyAggregates < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    unless pg_partman_available?
      if Rails.env.production?
        raise ActiveRecord::MigrationError,
          "TASK-039 partitioning: pg_partman extension required in production " \
          "но недоступен. DBA должен установить pg_partman >= 4.7 на DB сервере " \
          "перед повторным запуском миграции. См. ADR §4.2."
      end

      warn "[TASK-039 Migration #5] pg_partman extension недоступен в #{Rails.env} — skip partitioning. " \
           "В production миграция raise."
      return
    end

    execute "CREATE EXTENSION IF NOT EXISTS pg_partman"

    # Partition management в отдельной транзакции —
    # если UPDATE part_config упадёт, create_parent уже done (idempotent через partman state).
    ActiveRecord::Base.transaction do
      execute <<~SQL
        SELECT partman.create_parent(
          p_parent_table => 'public.trends_daily_aggregates',
          p_control => 'date',
          p_type => 'native',
          p_interval => 'monthly',
          p_premake => 4,
          p_start_partition => to_char(CURRENT_DATE, 'YYYY-MM-01')
        );
      SQL

      execute <<~SQL
        UPDATE partman.part_config
        SET retention = '2 years',
            retention_keep_table = false,
            retention_keep_index = false
        WHERE parent_table = 'public.trends_daily_aggregates';
      SQL
    end
  rescue ActiveRecord::StatementInvalid => e
    raise if Rails.env.production?

    warn "[TASK-039 Migration #5] partman setup failed in #{Rails.env}: #{e.message}"
  end

  def down
    # pg_partman undo_partition НЕ чистый reverse: либо создаёт divergent unpart table,
    # либо требует pg_partman >= 4.7 для in-place consolidation. Production rollback:
    # 1. pg_dump данных из trends_daily_aggregates_p* партиций
    # 2. SELECT partman.undo_partition('public.trends_daily_aggregates') — вручную
    # 3. DELETE FROM partman.part_config WHERE parent_table = '...'
    # 4. DROP EXTENSION pg_partman CASCADE (если не нужен другим таблицам)
    # 5. pg_restore данных в unpartitioned trends_daily_aggregates
    raise ActiveRecord::IrreversibleMigration,
      "TASK-039 partitioning down требует ручного rollback процесса — см. комментарий в миграции. " \
      "Automated down скрывал бы data loss risks."
  end

  private

  def pg_partman_available?
    result = execute(<<~SQL).first
      SELECT 1 FROM pg_available_extensions WHERE name = 'pg_partman' LIMIT 1
    SQL
    !result.nil?
  rescue StandardError => e
    warn "[TASK-039] pg_partman availability check failed: #{e.message}"
    false
  end
end
