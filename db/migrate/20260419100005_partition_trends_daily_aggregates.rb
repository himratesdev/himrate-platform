# frozen_string_literal: true

# TASK-039 ADR §4.2: pg_partman monthly partitions для trends_daily_aggregates.
# 100k channels × 365d = 36.5M rows/year, 5y = 180M+. Per-partition ~3M rows.
# Retention 2 years (drop старых партиций мгновенно vs months DELETE).
#
# ВАЖНО: эта миграция требует EXTENSION pg_partman на DB сервере.
# Если pg_partman недоступен (dev без extension) — миграция skip с warning.
# Production deploy: DBA устанавливает pg_partman перед deploy.

class PartitionTrendsDailyAggregates < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    if pg_partman_available?
      execute "CREATE EXTENSION IF NOT EXISTS pg_partman"

      # NB: для conversion existing table в partitioned требуется pg_partman 4.7+.
      # На MVP канал свежий — partman просто берет управление пустой таблицей.
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
    else
      warn "[TASK-039 Migration #5] pg_partman extension недоступен — skip partitioning. " \
           "Production: установить pg_partman, повторно запустить миграцию вручную."
    end
  end

  def down
    return unless pg_partman_available?

    execute <<~SQL
      SELECT partman.undo_partition(
        p_parent_table => 'public.trends_daily_aggregates',
        p_target_table => 'public.trends_daily_aggregates_unpart'
      );
    SQL
    execute "DELETE FROM partman.part_config WHERE parent_table = 'public.trends_daily_aggregates'"
  end

  private

  def pg_partman_available?
    result = execute(<<~SQL).first
      SELECT 1 FROM pg_available_extensions WHERE name = 'pg_partman' LIMIT 1
    SQL
    !result.nil?
  rescue StandardError => e
    warn "[TASK-039] pg_partman check failed: #{e.message}"
    false
  end
end
