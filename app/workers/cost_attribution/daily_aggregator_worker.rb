# frozen_string_literal: true

# BUG-010 PR2 (FR-109/110): cost attribution daily aggregator (dormant pre-launch).
# Sums recent downtime events × cost calculator → emits Prometheus metrics для dashboard.

module CostAttribution
  class DailyAggregatorWorker
    include Sidekiq::Job
    sidekiq_options queue: :accessory_ops, retry: 2

    def perform
      AccessoryDowntimeEvent.recent.find_each do |event|
        cost_usd = CostAttribution::DowntimeCostCalculator.call(event)
        next if cost_usd.zero?

        PrometheusMetrics.observe_downtime_cost(
          destination: event.destination,
          accessory: event.accessory,
          cost_usd: cost_usd
        )
      end
    rescue StandardError => e
      Rails.logger.error("CostAttribution::DailyAggregatorWorker: #{e.class}: #{e.message}")
      raise
    end
  end
end
