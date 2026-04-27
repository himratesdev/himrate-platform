# frozen_string_literal: true

# BUG-010 PR2 (FR-106/111, ADR DEC-18): cost attribution для accessory downtime.
# Returns $0 если revenue_baseline empty (pre-launch dormant). Post-launch:
# (duration_seconds / 86400) * latest_daily_revenue_usd * accessory_revenue_weight.

module CostAttribution
  class DowntimeCostCalculator
    def self.call(downtime_event)
      return 0.0 unless downtime_event.duration_seconds

      baseline = RevenueBaseline.latest
      return 0.0 unless baseline

      weight = baseline.weight_for(downtime_event.accessory)
      return 0.0 if weight.zero?

      ((downtime_event.duration_seconds.to_f / 86_400) * baseline.daily_revenue_usd.to_f * weight).round(2)
    end
  end
end
