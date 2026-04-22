# frozen_string_literal: true

# TASK-039 FR-007/FR-014: Peer comparison percentile compute для стрим-канала
# в его category scope. Output shape per SRS §4.2 /trends/comparison:
#   {category, sample_size, channel_values, percentiles: {ti/erv/stability: p25/p50/p75/p90}, verdict}
#
# Min channels per category threshold (SignalConfiguration trends/peer_comparison/
# min_category_channels, default 100) — ниже = insufficient_category_data вердикт
# (SRS US-009). Cache 15m (expensive compute at 100k+ scale).
#
# Data source:
#   - TrendsDailyAggregate для TI/ERV aggregates + category (через categories jsonb)
#   - В period window (default 30d) per channel → latest avg per channel
#
# Stability computed через `1 - ti_std/ti_avg` формула (BR-008).

module Trends
  module Analysis
    class PeerComparisonService
      def self.call(channel:, category:, period:)
        new(channel: channel, category: category, period: period).call
      end

      def initialize(channel:, category:, period:)
        @channel = channel
        @category = category
        @period = period
      end

      def call
        min_channels = SignalConfiguration.value_for("trends", "peer_comparison", "min_category_channels").to_i
        cache_ttl_minutes = SignalConfiguration.value_for("trends", "peer_comparison", "cache_ttl_minutes").to_i

        key = "trends:peer_comparison:#{digest}:v1"
        Rails.cache.fetch(key, expires_in: cache_ttl_minutes.minutes, race_condition_ttl: 60.seconds) do
          compute(min_channels)
        end
      end

      private

      # Digest includes channel_id чтобы исключение self из baseline per channel.
      def digest
        Digest::SHA1.hexdigest("#{@channel.id}:#{@category}:#{@period}")
      end

      def compute(min_channels)
        peers = peer_aggregates
        return { category: @category, sample_size: peers.size, insufficient_data: true } if peers.size < min_channels

        channel_data = channel_aggregates
        {
          category: @category,
          sample_size: peers.size,
          channel_values: channel_data,
          percentiles: {
            ti: percentiles_for(peers.map { |p| p[:ti_avg] }),
            erv: percentiles_for(peers.map { |p| p[:erv_avg_percent] }),
            stability: percentiles_for(peers.map { |p| p[:stability] })
          },
          verdict: build_verdict(channel_data, peers)
        }
      end

      # Aggregates для peers (exclude self). Latest period avg per channel.
      def peer_aggregates
        from = period_start

        TrendsDailyAggregate
          .where.not(channel_id: @channel.id)
          .where("date >= ?", from)
          .where("jsonb_exists(categories, ?)", @category)
          .where.not(ti_avg: nil)
          .group(:channel_id)
          .pluck(
            :channel_id,
            Arel.sql("AVG(ti_avg)::numeric(5,2) AS ti_avg"),
            Arel.sql("AVG(erv_avg_percent)::numeric(5,2) AS erv_avg_percent"),
            Arel.sql("AVG(ti_std)::numeric(5,2) AS ti_std")
          )
          .map { |cid, ti, erv, std| { channel_id: cid, ti_avg: ti&.to_f, erv_avg_percent: erv&.to_f, stability: compute_stability(ti, std) } }
          .compact
      end

      def channel_aggregates
        from = period_start
        stats = TrendsDailyAggregate
          .where(channel_id: @channel.id, date: from..Date.current)
          .where("jsonb_exists(categories, ?)", @category)
          .where.not(ti_avg: nil)
          .pick(Arel.sql("AVG(ti_avg)"), Arel.sql("AVG(erv_avg_percent)"), Arel.sql("AVG(ti_std)"))

        return { ti_avg: nil, erv_avg_percent: nil, stability: nil } if stats.nil?

        {
          ti_avg: stats[0]&.to_f&.round(2),
          erv_avg_percent: stats[1]&.to_f&.round(2),
          stability: compute_stability(stats[0], stats[2])
        }
      end

      # BR-008: stability = 1 - CV = 1 - (ti_std / ti_avg). Guard against ti_avg=0.
      def compute_stability(ti_avg, ti_std)
        return nil if ti_avg.nil? || ti_std.nil?

        avg = ti_avg.to_f
        return nil if avg.zero?

        (1.0 - ti_std.to_f / avg).clamp(0.0, 1.0).round(3)
      end

      def period_start
        days =
          case @period
          when "7d" then 7
          when "30d" then 30
          when "60d" then 60
          when "90d" then 90
          when "365d" then 365
          else 30
          end
        days.days.ago.to_date
      end

      # Quartile percentiles (p25/p50/p75/p90) via sort+index.
      # Simple implementation — acceptable at 100-10000 peers range.
      def percentiles_for(values)
        valid = values.compact.sort
        return { p25: nil, p50: nil, p75: nil, p90: nil } if valid.empty?

        {
          p25: percentile(valid, 0.25),
          p50: percentile(valid, 0.50),
          p75: percentile(valid, 0.75),
          p90: percentile(valid, 0.90)
        }
      end

      # Linear interpolation between bracketing values (NIST R-7 method).
      def percentile(sorted, q)
        return nil if sorted.empty?

        rank = q * (sorted.size - 1)
        low = sorted[rank.floor]
        high = sorted[rank.ceil]
        result = low + (high - low) * (rank - rank.floor)
        result.round(2)
      end

      # CR S-4: i18n templates (не string interpolation) — extensible для new locales.
      def build_verdict(channel_data, _peers)
        ti = channel_data[:ti_avg]
        return { verdict_en: nil, verdict_ru: nil } if ti.nil?

        {
          verdict_en: I18n.t("trends.comparison.verdict", locale: :en, ti: ti, category: @category),
          verdict_ru: I18n.t("trends.comparison.verdict", locale: :ru, ti: ti, category: @category)
        }
      end
    end
  end
end
