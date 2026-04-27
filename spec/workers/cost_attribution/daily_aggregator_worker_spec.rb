# frozen_string_literal: true

require "rails_helper"

RSpec.describe CostAttribution::DailyAggregatorWorker do
  let(:worker) { described_class.new }

  before do
    allow(PrometheusMetrics).to receive(:observe_downtime_cost)
  end

  describe "#perform" do
    it "skip emission когда cost = 0 (pre-launch dormant baseline)" do
      AccessoryDowntimeEvent.create!(
        destination: "production", accessory: "db",
        started_at: 2.hours.ago, ended_at: 1.hour.ago, source: "drift"
      )
      worker.perform
      expect(PrometheusMetrics).not_to have_received(:observe_downtime_cost)
    end

    it "emits Prometheus observation когда cost > 0" do
      RevenueBaseline.create!(
        period_start: 30.days.ago.to_date, period_end: 1.day.ago.to_date,
        daily_revenue_usd: 1000.00, calculated_at: Time.current,
        accessory_revenue_weights: {}
      )
      AccessoryDowntimeEvent.create!(
        destination: "production", accessory: "db",
        started_at: 2.hours.ago, ended_at: 1.hour.ago, source: "drift"
      )
      worker.perform
      expect(PrometheusMetrics).to have_received(:observe_downtime_cost).with(
        destination: "production", accessory: "db", cost_usd: kind_of(Numeric)
      )
    end

    it "пропускает старые events за пределами .recent (30d default)" do
      RevenueBaseline.create!(
        period_start: 30.days.ago.to_date, period_end: 1.day.ago.to_date,
        daily_revenue_usd: 1000.00, calculated_at: Time.current,
        accessory_revenue_weights: {}
      )
      AccessoryDowntimeEvent.create!(
        destination: "production", accessory: "db",
        started_at: 40.days.ago, ended_at: 40.days.ago + 1.hour, source: "drift"
      )
      worker.perform
      expect(PrometheusMetrics).not_to have_received(:observe_downtime_cost)
    end

    it "raises stop Sidekiq retry при ошибке" do
      allow(AccessoryDowntimeEvent).to receive(:recent).and_raise(StandardError, "db connection lost")
      expect { worker.perform }.to raise_error(StandardError, "db connection lost")
    end
  end
end
