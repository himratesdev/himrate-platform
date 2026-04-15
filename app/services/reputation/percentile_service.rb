# frozen_string_literal: true

# TASK-037 FR-014/015/024: Percentile ranking within category.
# Uses DISTINCT ON to get latest HS per channel. Min 100 channels for meaningful percentile.
# Cached in Redis 5 min.

module Reputation
  class PercentileService
    MIN_CHANNELS = 100
    CACHE_TTL = 5.minutes

    def initialize(channel:)
      @channel = channel
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        compute
      end
    end

    private

    def compute
      hs = latest_hs_for(@channel.id)
      return nil unless hs

      category = @channel.streams.order(started_at: :desc).pick(:game_name)
      category_channels = channels_in_category(category)

      return nil if category_channels < MIN_CHANNELS

      below = count_below(hs, category)
      (below.to_f / category_channels * 100).round(1)
    end

    # FR-024: DISTINCT ON latest HS per channel
    def channels_in_category(category)
      scope = HealthScore.select("DISTINCT ON (channel_id) channel_id, health_score")
        .order(:channel_id, calculated_at: :desc)

      if category.present?
        channel_ids = Stream.where(game_name: category).select("DISTINCT channel_id")
        scope = scope.where(channel_id: channel_ids)
      end

      scope.count
    end

    def count_below(target_hs, category)
      subquery = HealthScore
        .select("DISTINCT ON (channel_id) channel_id, health_score")
        .order(:channel_id, calculated_at: :desc)

      if category.present?
        channel_ids = Stream.where(game_name: category).select("DISTINCT channel_id")
        subquery = subquery.where(channel_id: channel_ids)
      end

      HealthScore.from("(#{subquery.to_sql}) AS latest_hs")
        .where("latest_hs.health_score < ?", target_hs)
        .count
    end

    def latest_hs_for(channel_id)
      HealthScore.where(channel_id: channel_id).order(calculated_at: :desc).pick(:health_score)&.to_f
    end

    def cache_key
      "percentile:#{@channel.id}"
    end
  end
end
