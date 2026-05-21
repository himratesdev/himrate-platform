# frozen_string_literal: true

# TASK-A1 Visual QA (philosophy-v2): creates FollowerSnapshot daily rows —
# feeds Streamer Reputation Growth (TI signal) + follower-history UI surfaces.
#
# Distribution: daily snapshot для периода с realistic linear/sigmoidal growth.
# Idempotent via (channel_id, timestamp rounded к date).

module Trends
  module VisualQa
    class FollowerSnapshotSeeder
      def self.seed(channel:, days:, start_followers: 500, end_followers: 3000)
        new(channel: channel, days: days, start_followers: start_followers, end_followers: end_followers).seed
      end

      def initialize(channel:, days:, start_followers:, end_followers:)
        @channel = channel
        @days = days
        @start_followers = start_followers
        @end_followers = end_followers
      end

      def seed
        snapshots = []
        @days.times do |offset|
          date = (Date.current - offset.days)
          timestamp = date.beginning_of_day + 12.hours
          followers = logistic_growth_at(offset)

          snapshot = FollowerSnapshot.find_or_create_by!(channel_id: @channel.id, timestamp: timestamp) do |s|
            s.followers_count = followers
            s.new_followers_24h = offset.zero? ? 0 : (followers - logistic_growth_at(offset + 1)).clamp(0, Float::INFINITY).to_i
          end
          snapshots << snapshot
        end
        snapshots
      end

      private

      # Logistic-ish growth curve: slow start, steep middle, plateau. Organic
      # discovery phase pattern. newest (offset=0) = end_followers, oldest = start.
      def logistic_growth_at(offset)
        progress = (@days - offset).to_f / @days # 0..1 from oldest → newest
        # Sigmoid around midpoint — smooth organic S-curve.
        sigmoid = 1.0 / (1.0 + ::Math.exp(-6 * (progress - 0.5)))
        (@start_followers + (@end_followers - @start_followers) * sigmoid).round
      end
    end
  end
end
