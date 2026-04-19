# frozen_string_literal: true

# TASK-039 FR-015 + ADR §4.2: Daily aggregation layer, NATIVE PARTITIONED BY RANGE(date).
#
# Архитектурные инварианты PG native partitioning:
# 1. Parent table декларируется PARTITION BY RANGE(date) в CREATE TABLE (нет ALTER).
# 2. Partition key (date) должен быть в КАЖДОМ UNIQUE constraint (включая PK) —
#    PRIMARY KEY (id, date), UNIQUE (channel_id, date).
# 3. FK на parent допустим (PG 11+). Partial indexes через add_index propagate
#    на все partitions автоматически.
# 4. Default partition ловит любые даты вне диапазона — safety net для dev/test
#    без pg_partman. В prod pg_partman создаёт monthly partitions явно.
#
# schema_version=2 для cache versioning (config/initializers/trends.rb).
# 5 v2.0 columns per SRS §2.3 FR-015.

class CreateTrendsDailyAggregates < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE trends_daily_aggregates (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        channel_id uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        date date NOT NULL,

        -- Trust Index aggregates (0..100)
        ti_avg decimal(5,2),
        ti_std decimal(5,2),
        ti_min decimal(5,2),
        ti_max decimal(5,2),

        -- ERV aggregates (0..100 %)
        erv_avg_percent decimal(5,2),
        erv_min_percent decimal(5,2),
        erv_max_percent decimal(5,2),

        -- CCV (non-negative integer)
        ccv_avg integer,
        ccv_peak integer,

        -- Stream metadata
        streams_count integer NOT NULL DEFAULT 0,
        botted_fraction decimal(4,3),
        classification_at_end varchar(30),
        categories jsonb NOT NULL DEFAULT '{}',
        signal_breakdown jsonb NOT NULL DEFAULT '{}',

        -- v2.0 ШИРЕ extensions (TASK-039 SRS §2.3 FR-015)
        discovery_phase_score decimal(4,3),
        follower_ccv_coupling_r decimal(4,3),
        tier_change_on_day boolean NOT NULL DEFAULT false,
        is_best_stream_day boolean NOT NULL DEFAULT false,
        is_worst_stream_day boolean NOT NULL DEFAULT false,

        -- Cache versioning (ADR §4.12)
        schema_version integer NOT NULL DEFAULT 2,

        -- N-9 CR iter 3: DEFAULT now() для raw INSERT пути (workers' insert_all
        -- с partial column mapping). Rails AR callbacks заполнят timestamps
        -- при save, DB default — fallback для direct SQL writes.
        created_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(6) without time zone NOT NULL DEFAULT now(),

        -- Composite PK обязателен: partition key (date) в PK для native partitioning
        PRIMARY KEY (id, date),
        UNIQUE (channel_id, date)
      ) PARTITION BY RANGE (date);
    SQL

    # Default partition ловит все даты. В prod pg_partman создаёт monthly + default
    # остаётся пустым (safety net). В dev/test без pg_partman — catches все INSERT.
    execute(<<~SQL)
      CREATE TABLE trends_daily_aggregates_default
        PARTITION OF trends_daily_aggregates DEFAULT;
    SQL

    # Partial indexes на parent автоматически propagate на все partitions (PG 11+).
    add_index :trends_daily_aggregates, %i[channel_id tier_change_on_day],
      where: "tier_change_on_day = true",
      name: "idx_tda_tier_change"

    add_index :trends_daily_aggregates, %i[channel_id discovery_phase_score],
      where: "discovery_phase_score IS NOT NULL",
      name: "idx_tda_discovery"

    add_index :trends_daily_aggregates, %i[channel_id is_best_stream_day is_worst_stream_day],
      where: "is_best_stream_day = true OR is_worst_stream_day = true",
      name: "idx_tda_best_worst"
  end

  def down
    drop_table :trends_daily_aggregates
  end
end
