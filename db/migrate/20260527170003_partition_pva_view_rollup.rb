# frozen_string_literal: true

# TASK-113 BE-2: handoff pva_view_rollups partition management to pg_partman (monthly partitions).
# Зеркало 20260527160009 (raw) / TASK-039 #5, НО БЕЗ retention — rollup = lifetime durable store
# (M1 window=all / Spotify-Wrapped; raw 2y дропается, rollup живёт). partman даёт monthly-партиции
# для partition pruning на time-range запросах (last 7d/30d/90d → 1-2 партиции).
#
# В test (CI stock postgres:16, без partman) — skip: default partition ловит все INSERT.
# В staging/prod pg_partman обязателен (уже установлен — trends_daily_aggregates + pva_view_events).
# Down irreversible (undo_partition divergent state) — manual rollback в комментарии.
class PartitionPvaViewRollup < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    unless pg_partman_installed?
      if Rails.env.test?
        say "[TASK-113 BE-2] pg_partman skipped в test env — default partition handles INSERTs"
        return
      end

      raise ActiveRecord::MigrationError,
        "TASK-113: pg_partman extension required в #{Rails.env}. " \
        "Staging/Production: extension уже установлен (trends_daily_aggregates + pva_view_events)."
    end

    ActiveRecord::Base.transaction do
      start_partition = (Date.current.beginning_of_month - 3.months).strftime("%Y-%m-%d")

      # p_default_table => false — миграция 170002 уже создала pva_view_rollups_default.
      # НЕТ retention UPDATE (в отличие от raw 160009 / trends) — rollup хранится lifetime.
      execute(<<~SQL)
        SELECT partman.create_parent(
          p_parent_table => 'public.pva_view_rollups',
          p_control => 'date',
          p_interval => '1 month',
          p_premake => 4,
          p_start_partition => '#{start_partition}',
          p_default_table => false
        );
      SQL
    end
  end

  def down
    # undo_partition может создать divergent state. Production rollback:
    # 1. pg_dump pva_view_rollups_p*
    # 2. SELECT partman.undo_partition('public.pva_view_rollups') (manual)
    # 3. DELETE FROM partman.part_config WHERE parent_table = '...'
    # 4. Миграция 20260527170002 drop_table на rollback
    raise ActiveRecord::IrreversibleMigration,
      "TASK-113 pg_partman setup down требует manual rollback — см. комментарий."
  end

  private

  def pg_partman_installed?
    result = execute("SELECT 1 FROM pg_extension WHERE extname = 'pg_partman' LIMIT 1").first
    !result.nil?
  rescue StandardError => e
    say "[TASK-113] pg_partman installation check failed: #{e.message}"
    false
  end
end
