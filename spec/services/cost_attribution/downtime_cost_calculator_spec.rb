# frozen_string_literal: true

require "rails_helper"

RSpec.describe CostAttribution::DowntimeCostCalculator do
  let(:event) do
    AccessoryDowntimeEvent.create!(
      destination: "production", accessory: "db",
      started_at: 1.hour.ago, ended_at: Time.current, source: "drift"
    )
  end

  describe ".call" do
    it "returns 0.0 когда RevenueBaseline пуст (pre-launch dormant)" do
      expect(described_class.call(event)).to eq(0.0)
    end

    it "returns 0.0 когда weight=0 (observability accessory)" do
      RevenueBaseline.create!(
        period_start: 30.days.ago.to_date, period_end: 1.day.ago.to_date,
        daily_revenue_usd: 1000.00, calculated_at: Time.current,
        accessory_revenue_weights: {}
      )
      grafana_event = AccessoryDowntimeEvent.create!(
        destination: "production", accessory: "grafana",
        started_at: 1.hour.ago, ended_at: Time.current, source: "drift"
      )
      expect(described_class.call(grafana_event)).to eq(0.0)
    end

    it "computes (duration / 86400) * daily_revenue * weight per ADR DEC-18" do
      RevenueBaseline.create!(
        period_start: 30.days.ago.to_date, period_end: 1.day.ago.to_date,
        daily_revenue_usd: 1000.00, calculated_at: Time.current,
        accessory_revenue_weights: {}
      )
      # event длится ~3600 сек, db weight=1.0 → 3600/86400 * 1000 * 1.0 = 41.67
      cost = described_class.call(event)
      expect(cost).to be_within(0.5).of(41.67)
    end

    it "applies custom weight из accessory_revenue_weights" do
      RevenueBaseline.create!(
        period_start: 30.days.ago.to_date, period_end: 1.day.ago.to_date,
        daily_revenue_usd: 1000.00, calculated_at: Time.current,
        accessory_revenue_weights: { "db" => 0.5 }
      )
      cost = described_class.call(event)
      expect(cost).to be_within(0.5).of(20.83)
    end

    it "returns 0.0 когда duration_seconds nil" do
      live_event = AccessoryDowntimeEvent.create!(
        destination: "production", accessory: "db",
        started_at: 1.hour.ago, source: "restart"
      )
      RevenueBaseline.create!(
        period_start: 30.days.ago.to_date, period_end: 1.day.ago.to_date,
        daily_revenue_usd: 1000.00, calculated_at: Time.current,
        accessory_revenue_weights: {}
      )
      expect(described_class.call(live_event)).to eq(0.0)
    end
  end
end
