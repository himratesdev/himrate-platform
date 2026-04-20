# frozen_string_literal: true

# TASK-039 FR-015 + FR-018: Core daily aggregation — computes aggregated
# fields для `trends_daily_aggregates` из raw sources (Stream, TrustIndexHistory).
#
# Scope Phase B1a (core fields only):
#   - TI aggregates (avg/std/min/max) ← TrustIndexHistory WHERE calculated_at::date = target
#   - ERV aggregates (avg/min/max %) ← TrustIndexHistory.erv_percent
#   - CCV (avg/peak) ← Stream.avg_ccv / Stream.peak_ccv aggregated по streams on date
#   - streams_count ← Stream WHERE DATE(started_at) = target
#   - classification_at_end ← latest TIH.classification на date
#   - categories (jsonb) ← {game_name → count} по streams on date
#
# Deferred в Phase B3 (populated async by respective services, leaving NULL/default here):
#   - discovery_phase_score (DiscoveryPhaseDetector)
#   - follower_ccv_coupling_r (FollowerCcvCoupling)
#   - tier_change_on_day (TierChangeCounter)
#   - is_best_stream_day / is_worst_stream_day (BestWorstStreamFinder)
#   - botted_fraction (из Anomaly/BotDetection — part of B1b anomaly pipeline)
#   - signal_breakdown jsonb (aggregated TIH.signal_breakdown — deferred pending design)
#
# Idempotent: UPSERT через unique (channel_id, date). Concurrent worker safety
# handled by AggregationWorker's pg_advisory_lock (ADR §4.3).

module Trends
  module Aggregation
    class DailyBuilder
      # schema_version bumped для breaking changes response shape (ADR §4.12).
      # Current version defined в TrendsDailyAggregate::SUPPORTED_SCHEMA_VERSIONS.
      SCHEMA_VERSION = TrendsDailyAggregate::SUPPORTED_SCHEMA_VERSIONS.max

      def self.call(channel_id, date)
        new(channel_id, date).call
      end

      def initialize(channel_id, date)
        @channel_id = channel_id
        @date = date.is_a?(String) ? Date.parse(date) : date
      end

      def call
        day_start = @date.beginning_of_day
        day_end = @date.end_of_day

        streams_on_date = Stream
          .for_channel(@channel_id)
          .where(started_at: day_start..day_end)

        tih_on_date = TrustIndexHistory
          .for_channel(@channel_id)
          .where(calculated_at: day_start..day_end)

        attributes = build_attributes(streams_on_date, tih_on_date)

        # Upsert через unique (channel_id, date). Конкуренция защищена
        # pg_advisory_lock в AggregationWorker — single writer at a time.
        TrendsDailyAggregate.upsert(attributes, unique_by: %i[channel_id date])
      end

      private

      def build_attributes(streams, tih)
        ti_stats = ti_aggregates(tih)
        erv_stats = erv_aggregates(tih)
        ccv_stats = ccv_aggregates(streams)

        {
          channel_id: @channel_id,
          date: @date,
          streams_count: streams.count,
          categories: categories_breakdown(streams),
          classification_at_end: latest_classification(tih),
          schema_version: SCHEMA_VERSION
        }.merge(ti_stats).merge(erv_stats).merge(ccv_stats)
      end

      # TI aggregates: avg/std/min/max через single SQL query.
      # NULL returns если нет TIH rows — TrendsDailyAggregate validations allow_nil.
      def ti_aggregates(tih)
        stats = tih.pick(
          Arel.sql("AVG(trust_index_score)"),
          Arel.sql("STDDEV_POP(trust_index_score)"),
          Arel.sql("MIN(trust_index_score)"),
          Arel.sql("MAX(trust_index_score)")
        )
        return { ti_avg: nil, ti_std: nil, ti_min: nil, ti_max: nil } if stats.nil?

        {
          ti_avg: stats[0]&.to_f&.round(2),
          ti_std: stats[1]&.to_f&.round(2),
          ti_min: stats[2]&.to_f&.round(2),
          ti_max: stats[3]&.to_f&.round(2)
        }
      end

      # ERV aggregates из TrustIndexHistory.erv_percent (per stream TI compute).
      # Semantically avg/min/max для дня.
      def erv_aggregates(tih)
        stats = tih.where.not(erv_percent: nil).pick(
          Arel.sql("AVG(erv_percent)"),
          Arel.sql("MIN(erv_percent)"),
          Arel.sql("MAX(erv_percent)")
        )
        return { erv_avg_percent: nil, erv_min_percent: nil, erv_max_percent: nil } if stats.nil?

        {
          erv_avg_percent: stats[0]&.to_f&.round(2),
          erv_min_percent: stats[1]&.to_f&.round(2),
          erv_max_percent: stats[2]&.to_f&.round(2)
        }
      end

      # CCV aggregates из Stream.avg_ccv/peak_ccv (уже precomputed per stream).
      # Daily avg = среднее streams' avg_ccv. Daily peak = MAX peak_ccv.
      def ccv_aggregates(streams)
        stats = streams.where.not(avg_ccv: nil).pick(
          Arel.sql("AVG(avg_ccv)"),
          Arel.sql("MAX(peak_ccv)")
        )
        return { ccv_avg: nil, ccv_peak: nil } if stats.nil?

        {
          ccv_avg: stats[0]&.to_i,
          ccv_peak: stats[1]&.to_i
        }
      end

      # Categories breakdown: {game_name → stream_count}.
      # Used by Phase B3 CategoryPattern analysis service.
      def categories_breakdown(streams)
        streams.where.not(game_name: nil).group(:game_name).count
      end

      # Latest classification на день (по calculated_at DESC).
      # Используется для tier transition detection в Phase B3.
      def latest_classification(tih)
        tih.order(calculated_at: :desc).pick(:classification)
      end
    end
  end
end
