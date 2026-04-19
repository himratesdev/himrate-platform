# frozen_string_literal: true

# TASK-039 ADR §4.2: Handoff partition management to pg_partman.
#
# Prerequisite: migration #1 уже создала trends_daily_aggregates как native
# PARTITIONED BY RANGE(date) table + default partition. Эта миграция передаёт
# управление pg_partman: создаёт monthly partitions (-3 .. +4 months от now)
# и настраивает retention 2 years (drop старых партиций мгновенно).
#
# Backfill coverage: p_start_partition на 3 месяца назад для rake
# trends:backfill_aggregates (SRS §6) — исторические данные уходят в monthly
# partitions вместо default.
#
# pg_partman 5.x API (обязателен — Dockerfile pin'ит postgresql-16-partman 5.x):
#   • p_interval: PostgreSQL standard interval format ('1 month'). 4.x shortcut
#     'monthly' был removed в 5.0. Fail-loud если используется старый syntax.
#   • p_type: default 'range' (native PostgreSQL RANGE partitioning). 4.x
#     'native' keyword удалён — pg_partman 5.x supports только PostgreSQL-native
#     partitioning, flag больше не нужен.
#
# В production pg_partman ОБЯЗАТЕЛЕН (raise). В dev/test same — fail-fast
# раскрывает extension install bugs немедленно вместо silent skip, который
# маскирует broken production partitions.
#
# Down marked irreversible — undo_partition может создать divergent state,
# manual rollback procedure documented в def down.

class PartitionTrendsDailyAggregates < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    unless pg_partman_installed?
      raise ActiveRecord::MigrationError,
        "TASK-039: pg_partman extension required в #{Rails.env}. " \
        "Dev/test: после build custom postgres image (db/Dockerfile), перед " \
        "db:migrate execute 'CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman'. " \
        "Production: DBA должен выполнить CREATE EXTENSION (superuser) на accessory reboot."
    end

    ActiveRecord::Base.transaction do
      start_partition = (Date.current.beginning_of_month - 3.months).strftime("%Y-%m-%d")

      execute(<<~SQL)
        SELECT partman.create_parent(
          p_parent_table => 'public.trends_daily_aggregates',
          p_control => 'date',
          p_interval => '1 month',
          p_premake => 4,
          p_start_partition => '#{start_partition}'
        );
      SQL

      execute(<<~SQL)
        UPDATE partman.part_config
        SET retention = '2 years',
            retention_keep_table = false,
            retention_keep_index = false
        WHERE parent_table = 'public.trends_daily_aggregates';
      SQL
    end
  end

  def down
    # undo_partition может создать divergent state. Production rollback:
    # 1. pg_dump trends_daily_aggregates_p*
    # 2. SELECT partman.undo_partition('public.trends_daily_aggregates') (manual)
    # 3. DELETE FROM partman.part_config WHERE parent_table = '...'
    # 4. Миграция #1 drop_table на rollback
    raise ActiveRecord::IrreversibleMigration,
      "TASK-039 pg_partman setup down требует manual rollback — см. комментарий. " \
      "Automated down скрывал бы data loss."
  end

  private

  # Проверяет ЧТО extension INSTALLED (создан в DB), не только available (installable).
  # SF-6 CR iter 2: pg_available_extensions показывает installable, pg_extension — created.
  def pg_partman_installed?
    result = execute("SELECT 1 FROM pg_extension WHERE extname = 'pg_partman' LIMIT 1").first
    !result.nil?
  rescue StandardError => e
    say "[TASK-039] pg_partman installation check failed: #{e.message}"
    false
  end
end
