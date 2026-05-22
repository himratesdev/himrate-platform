# frozen_string_literal: true

# TASK-A1 SRS v3.0 §5.2 Migration 2: seed 4 SignalConfiguration rows под
# philosophy-v2 trends.{direction,weekday,categories} naming convention.
#
# Build-for-years: все trends.* thresholds tunable через admin DB updates без
# code deploy. Naming convention (direction/weekday/categories) явно
# differentiates philosophy-v2 services from legacy trends.{trend,patterns}.*
# (FR-036 candidates for future cleanup).
#
# Rows (4):
#   1. trends.direction.rising_slope_min = 0.1
#      — TrendCalculator threshold: slope ≥ 0.1 → "восходящий" classification.
#   2. trends.direction.declining_slope_max = -0.1
#      — TrendCalculator threshold: slope ≤ -0.1 → "нисходящий" classification.
#   3. trends.weekday.min_days = 14
#      — WeekdayPatternEndpointService: minimum days в period для valid weekday
#      pattern computation (insufficient_data → 400 для <14 days).
#   4. trends.categories.single_category_threshold_pct = 95
#      — CategoriesEndpointService: ≥95% времени в одной категории →
#      "monocategory" classification.
#
# Idempotent: find_or_create_by! (admin-tuned param_values preserved on re-runs).

class SeedTrendsV2SignalConfigurations < ActiveRecord::Migration[8.0]
  CONFIGS = [
    [ "trends", "direction", "rising_slope_min", 0.1 ],
    [ "trends", "direction", "declining_slope_max", -0.1 ],
    [ "trends", "weekday", "min_days", 14 ],
    [ "trends", "categories", "single_category_threshold_pct", 95 ]
  ].freeze

  def up
    CONFIGS.each do |signal_type, category, param_name, param_value|
      SignalConfiguration.find_or_create_by!(
        signal_type: signal_type,
        category: category,
        param_name: param_name
      ) { |c| c.param_value = param_value }
    end
  end

  def down
    CONFIGS.each do |signal_type, category, param_name, _|
      SignalConfiguration.where(
        signal_type: signal_type,
        category: category,
        param_name: param_name
      ).delete_all
    end
  end
end
