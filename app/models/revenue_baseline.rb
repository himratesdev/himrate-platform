# frozen_string_literal: true

# BUG-010 PR2: revenue baseline (dormant pre-launch — empty until financial pipeline populates).
# CostAttribution::DowntimeCostCalculator queries latest для cost estimation.
# accessory_revenue_weights JSONB per ADR DEC-18 (db=1.0, redis=0.8, observability=0.0).

class RevenueBaseline < ApplicationRecord
  DEFAULT_WEIGHTS = {
    "db" => 1.0,
    "redis" => 0.8,
    "grafana" => 0.0,
    "prometheus" => 0.0,
    "loki" => 0.0,
    "alertmanager" => 0.0,
    "promtail" => 0.0,
    "prometheus-pushgateway" => 0.0
  }.freeze

  validates :period_start, :period_end, :daily_revenue_usd, :calculated_at, presence: true
  validates :daily_revenue_usd, numericality: { greater_than_or_equal_to: 0 }
  validate :period_end_after_period_start

  def self.latest
    # Class method (not scope) — scope auto-wraps lambda return в Relation,
    # but caller (CostAttribution::DowntimeCostCalculator) ожидает single record.
    order(calculated_at: :desc).first
  end

  def weight_for(accessory)
    accessory_revenue_weights.fetch(accessory, DEFAULT_WEIGHTS.fetch(accessory, 0.0))
  end

  private

  def period_end_after_period_start
    return unless period_start && period_end
    errors.add(:period_end, "must be on or after period_start") if period_end < period_start
  end
end
