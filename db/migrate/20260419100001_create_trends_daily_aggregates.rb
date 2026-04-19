# frozen_string_literal: true

# TASK-039 FR-015: Aggregation layer для Trends Tab.
# Daily rollup TI/ERV/CCV/components per channel + v2.0 columns
# (discovery_phase, follower_ccv_coupling, tier_changes, best/worst markers).
# schema_version=2 для cache versioning. Partition-ready (см. миграцию 100005).

class CreateTrendsDailyAggregates < ActiveRecord::Migration[8.0]
  def change
    create_table :trends_daily_aggregates, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.date :date, null: false

      # Trust Index aggregates
      t.decimal :ti_avg, precision: 5, scale: 2
      t.decimal :ti_std, precision: 5, scale: 2
      t.decimal :ti_min, precision: 5, scale: 2
      t.decimal :ti_max, precision: 5, scale: 2

      # ERV aggregates
      t.decimal :erv_avg_percent, precision: 5, scale: 2
      t.decimal :erv_min_percent, precision: 5, scale: 2
      t.decimal :erv_max_percent, precision: 5, scale: 2

      # CCV
      t.integer :ccv_avg
      t.integer :ccv_peak

      # Stream metadata
      t.integer :streams_count, null: false, default: 0
      t.decimal :botted_fraction, precision: 4, scale: 3
      t.string :classification_at_end, limit: 30
      t.jsonb :categories, default: {}, null: false # { "Just Chatting" => 5, "Fortnite" => 2 }
      t.jsonb :signal_breakdown, default: {}, null: false # {auth_ratio: 0.78, ...}

      # v2.0 ШИРЕ extensions (TASK-039 SRS §2.3 FR-015)
      t.decimal :discovery_phase_score, precision: 4, scale: 3 # 0-1 organic-ness
      t.decimal :follower_ccv_coupling_r, precision: 4, scale: 3 # Pearson r 30d-rolling
      t.boolean :tier_change_on_day, null: false, default: false
      t.boolean :is_best_stream_day, null: false, default: false
      t.boolean :is_worst_stream_day, null: false, default: false

      # Cache versioning (bump on response shape change)
      t.integer :schema_version, null: false, default: 2

      t.timestamps
    end

    add_index :trends_daily_aggregates, %i[channel_id date],
      unique: true, name: "idx_tda_channel_date"

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
end
