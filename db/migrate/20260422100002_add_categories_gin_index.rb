# frozen_string_literal: true

# TASK-039 Phase C2: GIN index на trends_daily_aggregates.categories jsonb.
#
# Consumer services: PeerComparisonService + CategoryPattern используют
# `jsonb_exists(categories, ?)` scans. При 100k+ каналов без index sequential
# scan превышает SRS §8.1 p95 <5s target. jsonb_path_ops operator class optimized
# для `?` operator (existence check) — меньше index size vs default jsonb_ops.
#
# Pattern: zero-lock migration для partitioned table:
#   1. CREATE INDEX ON ONLY parent → метадата, invalid index, no data indexed
#   2. Для каждой existing partition: CREATE INDEX CONCURRENTLY → zero-lock
#      независимо от partition size (100GB+ safe)
#   3. ALTER INDEX parent ATTACH PARTITION child_index
#   4. Когда ВСЕ partitions attached → parent index автоматически VALID
#   5. Future partitions (pg_partman monthly rollouts) наследуют parent index
#      через PG 11+ PARTITION OF semantics
#
# PG 17 не поддерживает CREATE INDEX CONCURRENTLY на partitioned parent
# напрямую — ON ONLY + per-partition CONCURRENTLY pattern из PG docs §11.3.3
# (https://www.postgresql.org/docs/17/ddl-partitioning.html) единственный
# zero-lock путь на любом scale.

class AddCategoriesGinIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  INDEX_NAME = "idx_tda_categories_gin"
  PARENT_TABLE = "trends_daily_aggregates"

  def up
    return if parent_index_exists?

    # Step 1: metadata-only parent index (invalid until partitions attached).
    execute(<<~SQL)
      CREATE INDEX IF NOT EXISTS #{INDEX_NAME}
        ON ONLY #{PARENT_TABLE}
        USING GIN (categories jsonb_path_ops);
    SQL

    # Step 2-3: for each existing partition — concurrent build + attach.
    partition_names.each do |partition|
      partition_index = "#{partition}_categories_gin_idx"

      unless partition_index_exists?(partition_index)
        execute(<<~SQL)
          CREATE INDEX CONCURRENTLY IF NOT EXISTS #{partition_index}
            ON #{partition}
            USING GIN (categories jsonb_path_ops);
        SQL
      end

      next if partition_index_attached?(partition_index)

      execute("ALTER INDEX #{INDEX_NAME} ATTACH PARTITION #{partition_index};")
    end
    # Step 4: parent index auto-transitions INVALID → VALID когда все attached.
    # Step 5: future partitions inherit index через PG PARTITION OF.
  end

  def down
    return unless parent_index_exists?

    # Dropping parent drops attached per-partition indexes via dependency.
    execute("DROP INDEX IF EXISTS #{INDEX_NAME};")
  end

  private

  def parent_index_exists?
    ActiveRecord::Base.connection.select_value(
      "SELECT 1 FROM pg_indexes WHERE indexname = '#{INDEX_NAME}' AND tablename = '#{PARENT_TABLE}'"
    ).present?
  end

  def partition_index_exists?(index_name)
    ActiveRecord::Base.connection.select_value(
      "SELECT 1 FROM pg_indexes WHERE indexname = '#{index_name}'"
    ).present?
  end

  # pg_inherits enumerates children of partitioned parent (both pg_partman-managed
  # monthly partitions and default partition).
  def partition_names
    ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      WHERE p.relname = '#{PARENT_TABLE}'
      ORDER BY c.relname
    SQL
  end

  # Attached partition index has pg_inherits row с parent = INDEX_NAME.
  def partition_index_attached?(partition_index)
    ActiveRecord::Base.connection.select_value(<<~SQL).present?
      SELECT 1
      FROM pg_inherits i
      JOIN pg_class child ON child.oid = i.inhrelid
      JOIN pg_class parent ON parent.oid = i.inhparent
      WHERE child.relname = '#{partition_index}'
        AND parent.relname = '#{INDEX_NAME}'
    SQL
  end
end
