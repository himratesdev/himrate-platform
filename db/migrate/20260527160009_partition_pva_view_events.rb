# frozen_string_literal: true

# TASK-113 BE-1 (CR SF-2): handoff pva_view_events partition management to pg_partman.
#
# Prerequisite: миграция 20260527160001 уже создала pva_view_events как native
# PARTITIONED BY RANGE(started_at) table + default partition. Эта миграция передаёт
# управление pg_partman: создаёт monthly partitions (-3 .. +4 months от now) и настраивает
# retention 2 years (drop старых партиций мгновенно). Без неё ВСЕ inserts уходили бы в
# default-партицию навсегда — на самой высокообъёмной append-only PVA-таблице (per-сессия
# viewing-события всех зрителей). Точное зеркало trends migration #5 (TASK-039 ADR §4.2).
#
# Retention 2 года = PO-решение (2026-05-27): raw view-events прунятся, а агрегаты (ViewAggregation,
# BE-2) хранят lifetime-сводку вечно. User-initiated удаление — отдельно через M15 (BE-5).
#
# pg_partman 5.x API: p_interval = PostgreSQL interval ('1 month'); p_type default 'range'.
# В production/staging/dev pg_partman ОБЯЗАТЕЛЕН (raise) — extension стоит на custom db/Dockerfile
# image (тот же, что для trends). В test (CI stock postgres:16, без partman) — skip: default
# partition ловит все inserts, мы тестируем логику приложения, не partitioning mechanics.
#
# Down marked irreversible — undo_partition может создать divergent state, manual rollback в def down.
class PartitionPvaViewEvents < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    unless pg_partman_installed?
      if Rails.env.test?
        say "[TASK-113 SF-2] pg_partman skipped в test env — default partition handles INSERTs"
        return
      end

      raise ActiveRecord::MigrationError,
        "TASK-113: pg_partman extension required в #{Rails.env}. " \
        "Dev: запусти Postgres через custom image `db/Dockerfile`. " \
        "Staging/Production: extension уже установлен (используется trends_daily_aggregates)."
    end

    ActiveRecord::Base.transaction do
      start_partition = (Date.current.beginning_of_month - 3.months).strftime("%Y-%m-%d")

      # p_default_table => false — миграция #1 уже создала pva_view_events_default. pg_partman 5.x
      # create_parent по defaults пытался бы создать свою default ('already a partition'). Передаём
      # false → использует существующую default. ARCHITECTURAL CONSEQUENCE: default НЕ под retention
      # (active monthly window = current-3 .. current+4 мес via p_premake=4 + start offset). Routine
      # rows должны попадать в monthly-партиции; baseline default COUNT = 0 в healthy state.
      execute(<<~SQL)
        SELECT partman.create_parent(
          p_parent_table => 'public.pva_view_events',
          p_control => 'started_at',
          p_interval => '1 month',
          p_premake => 4,
          p_start_partition => '#{start_partition}',
          p_default_table => false
        );
      SQL

      execute(<<~SQL)
        UPDATE partman.part_config
        SET retention = '2 years',
            retention_keep_table = false,
            retention_keep_index = false
        WHERE parent_table = 'public.pva_view_events';
      SQL
    end
  end

  def down
    # undo_partition может создать divergent state. Production rollback:
    # 1. pg_dump pva_view_events_p*
    # 2. SELECT partman.undo_partition('public.pva_view_events') (manual)
    # 3. DELETE FROM partman.part_config WHERE parent_table = '...'
    # 4. Миграция 20260527160001 drop_table на rollback
    raise ActiveRecord::IrreversibleMigration,
      "TASK-113 pg_partman setup down требует manual rollback — см. комментарий. " \
      "Automated down скрывал бы data loss."
  end

  private

  # Проверяет ЧТО extension INSTALLED (создан в DB), не только available.
  def pg_partman_installed?
    result = execute("SELECT 1 FROM pg_extension WHERE extname = 'pg_partman' LIMIT 1").first
    !result.nil?
  rescue StandardError => e
    say "[TASK-113] pg_partman installation check failed: #{e.message}"
    false
  end
end
