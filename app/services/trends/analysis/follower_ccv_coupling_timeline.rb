# frozen_string_literal: true

# TASK-039 FR-030: Rolling 30-day Pearson r(followers, ccv_avg) per day.
# Outputs timeline array [{date, r, health}] consumed by /trends/components (M5).
# Также persists `follower_ccv_coupling_r` в trends_daily_aggregates (DailyBuilder B3 hook).
#
# Health classification:
#   - healthy   : r ≥ healthy_r_min (default 0.7)
#   - weakening : weakening_r_min ≤ r < healthy_r_min
#   - decoupled : r < weakening_r_min (red flag — possible viewbotting)
#
# Thresholds и rolling window в SignalConfiguration (trends/coupling/*).
# Minimum history: min_history_days (default 7). Early days in period → nil r.

module Trends
  module Analysis
    class FollowerCcvCouplingTimeline
      # CR W-2: Accept channel OR channel_id — avoids unnecessary Channel.find_by
      # в callers у которых есть только id (AggregationWorker → DailyBuilder).
      def self.call(channel: nil, channel_id: nil, from:, to:)
        new(channel: channel, channel_id: channel_id, from: from, to: to).call
      end

      def initialize(channel:, channel_id:, from:, to:)
        @channel_id = channel&.id || channel_id
        raise ArgumentError, "channel or channel_id required" if @channel_id.nil?

        @from = from
        @to = to
      end

      def call
        window = SignalConfiguration.value_for("trends", "coupling", "rolling_window_days").to_i
        min_history = SignalConfiguration.value_for("trends", "coupling", "min_history_days").to_i
        healthy_r = SignalConfiguration.value_for("trends", "coupling", "healthy_r_min").to_f
        weakening_r = SignalConfiguration.value_for("trends", "coupling", "weakening_r_min").to_f

        followers = follower_daily_series(@from - window.days, @to)
        ccv = ccv_daily_series(@from - window.days, @to)

        timeline = (@from..@to).map do |day|
          window_start = day - (window - 1).days
          pairs = aligned_pairs(followers, ccv, window_start, day)
          r = pairs.size >= min_history ? Trends::Analysis::Math::LinearRegression.pearson_r(pairs) : nil

          {
            date: day,
            r: r,
            health: classify_health(r, healthy_r, weakening_r)
          }
        end

        {
          timeline: timeline,
          summary: summarize(timeline, healthy_r, weakening_r)
        }
      end

      private

      # Latest follower count per day (channel-level, source: follower_snapshots).
      def follower_daily_series(from, to)
        FollowerSnapshot
          .where(channel_id: @channel_id)
          .where(timestamp: from.beginning_of_day..to.end_of_day)
          .pluck(Arel.sql("DATE(timestamp)"), :followers_count)
          .group_by(&:first)
          .transform_values { |rows| rows.map { |_, v| v.to_i }.max }
      end

      def ccv_daily_series(from, to)
        TrendsDailyAggregate
          .where(channel_id: @channel_id, date: from..to)
          .where.not(ccv_avg: nil)
          .pluck(:date, :ccv_avg)
          .to_h
      end

      def aligned_pairs(followers, ccv, from, to)
        (from..to).filter_map do |day|
          f = followers[day]
          c = ccv[day]
          next nil if f.nil? || c.nil?

          [ f, c ]
        end
      end

      def classify_health(r, healthy_r, weakening_r)
        return nil if r.nil?
        return "healthy" if r >= healthy_r
        return "weakening" if r >= weakening_r

        "decoupled"
      end

      def summarize(timeline, healthy_r, weakening_r)
        valid = timeline.filter_map { |row| row[:r] }
        return { current_r: nil, current_health: nil, avg_r: nil } if valid.empty?

        current = timeline.reverse.find { |row| !row[:r].nil? }
        {
          current_r: current&.dig(:r),
          current_health: current&.dig(:health),
          avg_r: (valid.sum / valid.size).round(4),
          healthy_threshold: healthy_r,
          weakening_threshold: weakening_r
        }
      end
    end
  end
end
