# frozen_string_literal: true

# TASK-038 FR-019 / AR-01: Per-component percentile within category.
# Single-query design (UNION ALL) instead of N queries per component.
# Latest HS per channel + freshness filter (30d). Min 50 channels in category.
# Redis cache 5min.

module Hs
  class ComponentPercentileService
    MIN_CHANNELS = 50
    CACHE_TTL = 5.minutes
    COMPONENTS = %w[ti stability engagement growth consistency].freeze
    FRESHNESS_WINDOW = 30.days

    def initialize(channel)
      @channel = channel
    end

    def call(category_key)
      Rails.cache.fetch(cache_key(category_key), expires_in: CACHE_TTL) do
        compute(category_key)
      end
    end

    private

    def compute(category_key)
      latest_hs = HealthScore
        .where(channel_id: @channel.id)
        .order(calculated_at: :desc)
        .first
      return nil unless latest_hs

      current_values = COMPONENTS.each_with_object({}) do |comp, hash|
        hash[comp.to_sym] = latest_hs.public_send("#{comp}_component")&.to_f
      end

      total_channels = channels_in_category(category_key)
      return nil if total_channels < MIN_CHANNELS

      counts_below = count_channels_below(category_key, current_values)

      COMPONENTS.each_with_object({}) do |comp, hash|
        value = current_values[comp.to_sym]
        count = counts_below[comp]
        hash[comp.to_sym] = value.nil? ? nil : ((count.to_f / total_channels) * 100).round(1)
      end
    end

    def channels_in_category(category_key)
      subquery = HealthScore
        .select("DISTINCT ON (channel_id) channel_id, category, calculated_at")
        .where("calculated_at > ?", FRESHNESS_WINDOW.ago)
        .where(category: category_key)
        .order(:channel_id, calculated_at: :desc)

      HealthScore.from("(#{subquery.to_sql}) AS latest_hs").count
    end

    # Single UNION query: one row per component with count_below
    def count_channels_below(category_key, current_values)
      parts = COMPONENTS.filter_map do |comp|
        value = current_values[comp.to_sym]
        next nil if value.nil?

        col = "#{comp}_component"
        <<~SQL.squish
          SELECT '#{comp}' AS component, COUNT(*) AS cnt
          FROM (
            SELECT DISTINCT ON (channel_id) channel_id, #{col} AS value, calculated_at
            FROM health_scores
            WHERE category = #{ActiveRecord::Base.connection.quote(category_key)}
              AND calculated_at > #{ActiveRecord::Base.connection.quote(FRESHNESS_WINDOW.ago)}
              AND channel_id != #{ActiveRecord::Base.connection.quote(@channel.id)}
            ORDER BY channel_id, calculated_at DESC
          ) latest_hs
          WHERE value < #{value.to_f}
        SQL
      end

      return {} if parts.empty?

      sql = parts.join(" UNION ALL ")
      result = ActiveRecord::Base.connection.exec_query(sql)
      result.rows.to_h { |r| [ r[0], r[1].to_i ] }
    end

    def cache_key(category_key)
      version = SignalConfiguration
        .where(signal_type: "health_score", category: category_key)
        .maximum(:updated_at)&.to_i || 0
      "hs:component_percentile:#{category_key}:v#{version}:#{@channel.id}"
    end
  end
end
