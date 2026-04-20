# frozen_string_literal: true

# TASK-039 Phase A3a (FR-046): Per-component percentile в Reputation domain
# (analogous Hs::ComponentPercentileService которое работает с health_scores).
#
# Reads streamer_reputations table — domain owner для components:
#   :growth_pattern, :follower_quality, :engagement_consistency, :pattern_history
# Все computed by StreamerReputationRefreshWorker (TASK-037).
#
# Используется:
#   - PostStreamWorker hook (Phase A3a) → snapshot percentiles в trust_index_history
#   - BonusAcceleratorCalculator (Phase A3b) → qualifying determination
#   - Future: peer comparison dashboards, advertiser metrics
#
# Pattern идентичен Hs::ComponentPercentileService:
#   single UNION query (no N+1), latest-per-channel via DISTINCT ON,
#   freshness window 30d, min channels threshold, Redis cache 5min.
#
# Min channels = 100 (matches existing Reputation::PercentileService threshold —
# Reputation требует больше data чем HS чтобы percentile был meaningful;
# reputation components volatile вне sufficient sample).

module Reputation
  class ComponentPercentileService
    MIN_CHANNELS = 100
    CACHE_TTL = 5.minutes
    COMPONENTS = %w[growth_pattern follower_quality engagement_consistency pattern_history].freeze
    FRESHNESS_WINDOW = 30.days

    def initialize(channel)
      @channel = channel
    end

    # Returns Hash { growth_pattern: 85.3, follower_quality: 72.1, engagement_consistency: 91.0, pattern_history: 88.5 }
    # OR nil если канал has no reputation OR < MIN_CHANNELS в категории.
    # Per-component value может быть nil если component not computed для канала.
    def call(category_key)
      Rails.cache.fetch(cache_key(category_key), expires_in: CACHE_TTL) do
        compute(category_key)
      end
    end

    private

    def compute(category_key)
      latest_rep = StreamerReputation.latest_for(@channel.id)
      return nil unless latest_rep

      current_values = COMPONENTS.each_with_object({}) do |comp, hash|
        hash[comp.to_sym] = latest_rep.public_send("#{comp}_score")&.to_f
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

    # Latest reputation per channel в категории, freshness 30d.
    # Category = latest stream's game_name → derived per channel via Stream.
    # Pattern matches Reputation::PercentileService (line 38-48).
    def channels_in_category(category_key)
      reputation_subq = StreamerReputation
        .select("DISTINCT ON (channel_id) channel_id, calculated_at")
        .where("calculated_at > ?", FRESHNESS_WINDOW.ago)
        .order(:channel_id, calculated_at: :desc)

      base = StreamerReputation.from("(#{reputation_subq.to_sql}) AS latest_rep")
      base = filter_by_category(base, category_key) unless category_default?(category_key)
      base.count
    end

    # Single UNION query: one row per component с count_below.
    # Mirrors Hs::ComponentPercentileService pattern exactly для consistency.
    # Все interpolations контролируемые: comp ∈ COMPONENTS hardcoded constant,
    # value/channel_id sanitized via .to_f и connection.quote.
    def count_channels_below(category_key, current_values)
      category_filter = category_default?(category_key) ? "" : category_filter_sql(category_key)

      parts = COMPONENTS.filter_map do |comp|
        value = current_values[comp.to_sym]
        next nil if value.nil?

        col = "#{comp}_score"

        <<~SQL.squish
          SELECT '#{comp}' AS component, COUNT(*) AS cnt
          FROM (
            SELECT DISTINCT ON (channel_id) channel_id, #{col} AS value, calculated_at
            FROM streamer_reputations
            WHERE calculated_at > #{ActiveRecord::Base.connection.quote(FRESHNESS_WINDOW.ago)}
              AND channel_id != #{ActiveRecord::Base.connection.quote(@channel.id)}
            ORDER BY channel_id, calculated_at DESC
          ) latest_rep
          WHERE value < #{value.to_f}
          #{category_filter}
        SQL
      end

      return {} if parts.empty?

      sql = parts.join(" UNION ALL ")
      result = ActiveRecord::Base.connection.exec_query(sql)
      result.rows.to_h { |r| [ r[0], r[1].to_i ] }
    end

    def category_default?(category_key)
      category_key.blank? || category_key == "default"
    end

    # Category filter via Stream → HealthScore join. AR-compiled WHERE c parameterized
    # bind values (no string interpolation в WHERE clause).
    def filter_by_category(scope, category_key)
      scope.where(channel_id: channel_ids_for_category(category_key))
    end

    # Hardcoded column reference "latest_rep.channel_id" в SQL (не interpolated parameter)
    # — Brakeman-safe, channel_ids_for_category возвращает sanitized SQL fragment.
    def category_filter_sql(category_key)
      ids_sql = channel_ids_for_category_sql(category_key)
      "AND latest_rep.channel_id IN (#{ids_sql})"
    end

    def channel_ids_for_category(category_key)
      Stream
        .joins("INNER JOIN health_scores hs ON hs.channel_id = streams.channel_id")
        .where(hs: { category: category_key })
        .distinct
        .pluck(:channel_id)
    end

    def channel_ids_for_category_sql(category_key)
      Stream
        .select("DISTINCT streams.channel_id")
        .joins("INNER JOIN health_scores hs ON hs.channel_id = streams.channel_id")
        .where(hs: { category: category_key })
        .to_sql
    end

    # Cache versioned by SignalConfiguration changes (matches Hs pattern).
    # Reputation thresholds в SignalConfiguration намечены под TASK-079 (currently
    # nothing reputation-specific). Fallback version=0 OK.
    def cache_key(category_key)
      version = SignalConfiguration
        .where(signal_type: "reputation", category: category_key)
        .maximum(:updated_at)&.to_i || 0
      "reputation:component_percentile:#{category_key}:v#{version}:#{@channel.id}"
    end
  end
end
