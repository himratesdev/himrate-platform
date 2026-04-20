# frozen_string_literal: true

# TASK-039 FR-028: Per-category TI/ERV breakdown for channel vs category baseline.
# Output shape (M12 /trends/categories):
#   [{name, streams_count, ti_avg, erv_avg_percent,
#     vs_baseline_ti_delta, vs_baseline_erv_delta}, ...]
#
# Source: trends_daily_aggregates.categories jsonb ({game_name => stream_count})
#   + ti_avg / erv_avg_percent на ROW level. Expand jsonb keys to per-category rows.
# Baseline: global category median (latest 30d window across all channels).
#   Uses Rails.cache (5 min TTL) to amortize global scan.
#
# Single-category protection: трансляция в основном в одной категории →
# если share ≥ single_threshold_pct (default 95) и других < 3 streams → skip deltas
# (noise suppression, avoid misleading "vs baseline" когда канал не diversified).

module Trends
  module Analysis
    class CategoryPattern
      BASELINE_WINDOW_DAYS = 30
      BASELINE_CACHE_TTL = 5.minutes

      def self.call(channel:, from:, to:)
        new(channel: channel, from: from, to: to).call
      end

      def initialize(channel:, from:, to:)
        @channel = channel
        @from = from
        @to = to
      end

      def call
        categories = channel_category_breakdown
        return { categories: [], verdict: nil, single_category: false } if categories.empty?

        total_streams = categories.sum { |c| c[:streams_count] }
        single_threshold_pct = SignalConfiguration.value_for("trends", "patterns", "category_single_threshold_pct").to_f
        dominant_share = (categories.first[:streams_count].to_f / total_streams) * 100

        enriched = categories.map do |row|
          baseline = category_baseline(row[:name])
          {
            **row,
            vs_baseline_ti_delta: delta(row[:ti_avg], baseline[:ti_avg]),
            vs_baseline_erv_delta: delta(row[:erv_avg_percent], baseline[:erv_avg_percent])
          }
        end

        {
          categories: enriched,
          single_category: dominant_share >= single_threshold_pct,
          top_category: enriched.first&.dig(:name),
          total_streams: total_streams
        }
      end

      private

      def channel_category_breakdown
        rows = TrendsDailyAggregate
          .where(channel_id: @channel.id, date: @from..@to)
          .where.not(ti_avg: nil)
          .pluck(:categories, :ti_avg, :erv_avg_percent)

        by_category = Hash.new { |h, k| h[k] = { streams: 0, ti_sum: 0.0, ti_weight: 0, erv_sum: 0.0, erv_weight: 0 } }

        rows.each do |categories_hash, ti_avg, erv_avg|
          next if categories_hash.blank?

          categories_hash.each do |name, count|
            bucket = by_category[name]
            count_i = count.to_i
            bucket[:streams] += count_i
            if ti_avg
              bucket[:ti_sum] += ti_avg.to_f * count_i
              bucket[:ti_weight] += count_i
            end
            if erv_avg
              bucket[:erv_sum] += erv_avg.to_f * count_i
              bucket[:erv_weight] += count_i
            end
          end
        end

        by_category
          .map do |name, b|
            {
              name: name,
              streams_count: b[:streams],
              ti_avg: b[:ti_weight].positive? ? (b[:ti_sum] / b[:ti_weight]).round(2) : nil,
              erv_avg_percent: b[:erv_weight].positive? ? (b[:erv_sum] / b[:erv_weight]).round(2) : nil
            }
          end
          .sort_by { |c| -c[:streams_count] }
      end

      # CR S-2: baseline ДОЛЖЕН исключать сам канал — self-comparison даёт
      # delta ≈ 0 для monopolist channel в niche категории. Cache keyed и по
      # channel_id тоже, т.к. baseline per-channel (exclude self) teraz varies.
      def category_baseline(name)
        # Digest name + channel_id to avoid Memcached key-length / charset issues.
        digest = Digest::SHA1.hexdigest("#{@channel.id}:#{name}")
        key = "trends:category_baseline:excl:#{digest}:v2"
        Rails.cache.fetch(key, expires_in: BASELINE_CACHE_TTL) do
          since = BASELINE_WINDOW_DAYS.days.ago.to_date
          # jsonb_exists wraps PG `?` operator as function — safe from Rails
          # placeholder parser confusion (see CR note on string-operator collision).
          # where.not(channel_id) исключает self из глобальной baseline per CR S-2.
          scope = TrendsDailyAggregate
            .where.not(channel_id: @channel.id)
            .where("date >= ?", since)
            .where("jsonb_exists(categories, ?)", name)
            .where.not(ti_avg: nil)
          stats = scope.pick(
            Arel.sql("AVG(ti_avg)"),
            Arel.sql("AVG(erv_avg_percent)")
          )
          {
            ti_avg: stats&.first&.to_f&.round(2),
            erv_avg_percent: stats&.last&.to_f&.round(2)
          }
        end
      end

      def delta(channel_value, baseline_value)
        return nil if channel_value.nil? || baseline_value.nil?

        (channel_value - baseline_value).round(2)
      end
    end
  end
end
