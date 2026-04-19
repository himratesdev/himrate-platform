# frozen_string_literal: true

# TASK-039 FR-017: Channel timezone для корректных границ дня в daily_aggregates.
# Default UTC. Lazy-detected при наличии данных (rake trends:detect_timezones).
# Используется TrendsAggregationWorker для группировки streams по local-day канала.

class AddTimezoneToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :timezone, :string, limit: 50, null: false, default: "UTC"
    add_index :channels, :timezone,
      where: "timezone != 'UTC'",
      name: "idx_channels_non_utc_timezone"
  end
end
