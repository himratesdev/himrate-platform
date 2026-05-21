# frozen_string_literal: true

# TASK-A1 Visual QA (philosophy-v2): populates trends_daily_aggregates через
# production DailyBuilder. Reuses real aggregation pipeline — ensures VQA data
# identical в shape к real post-stream flow.
#
# Invoked AFTER TihHistorySeeder (нужны TIH rows для aggregation).

module Trends
  module VisualQa
    class TdaAggregateSeeder
      def self.seed(channel:, streams:)
        new(channel: channel, streams: streams).seed
      end

      def initialize(channel:, streams:)
        @channel = channel
        @streams = streams
      end

      def seed
        dates = @streams.map { |s| s.started_at.to_date }.uniq
        dates.map do |date|
          Trends::Aggregation::DailyBuilder.call(@channel.id, date)
          TrendsDailyAggregate.find_by(channel_id: @channel.id, date: date)
        end.compact
      end
    end
  end
end
