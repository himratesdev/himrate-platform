# frozen_string_literal: true

# T1-074 PR3b — additive TI v2 columns on the Trends daily aggregate (DEC-3 ADD-not-rewrite
# pattern; parent-table add_column propagates to all PG native partitions automatically).
# v2 basis: authenticity_* (0-100 scalar, heir of ti_*), erv_avg_count (native real-viewer count —
# the % derivation dies with v1), band_*_at_end (6-row verdict, replaces classification_at_end
# whose trusted/needs_review taxonomy has no v2 equivalent). v1 columns stay (mixed windows persist
# for the TDA retention; readers COALESCE — see Brand::StreamerSearchQuery). Schema version 3→4.
class AddTiV2ColumnsToTrendsDailyAggregates < ActiveRecord::Migration[8.0]
  def change
    add_column :trends_daily_aggregates, :authenticity_avg, :decimal, precision: 5, scale: 2, if_not_exists: true
    add_column :trends_daily_aggregates, :authenticity_std, :decimal, precision: 5, scale: 2, if_not_exists: true
    add_column :trends_daily_aggregates, :authenticity_min, :decimal, precision: 5, scale: 2, if_not_exists: true
    add_column :trends_daily_aggregates, :authenticity_max, :decimal, precision: 5, scale: 2, if_not_exists: true
    add_column :trends_daily_aggregates, :erv_avg_count, :decimal, precision: 12, scale: 2, if_not_exists: true
    add_column :trends_daily_aggregates, :band_row_at_end, :integer, limit: 2, if_not_exists: true
    add_column :trends_daily_aggregates, :band_color_at_end, :string, limit: 8, if_not_exists: true
  end
end
