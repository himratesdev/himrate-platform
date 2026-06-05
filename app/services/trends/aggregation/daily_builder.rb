# frozen_string_literal: true

# TASK-A1 FR-015 + FR-018 (philosophy-v2): Core daily aggregation.
#
# Per-channel UPSERT into trends_daily_aggregates на date:
#   - TI aggregates (avg/std/min/max) ← TrustIndexHistory WHERE calculated_at::date = target
#   - ERV aggregates (avg/min/max %) ← TrustIndexHistory.erv_percent
#   - CCV (avg/peak) ← PostStreamReport.ccv_avg / ccv_peak (joined on streams ended_at present)
#     PR-A1: было `Stream.avg_ccv / Stream.peak_ccv`, эти колонки удалены — единый источник
#     истины для ENDED streams = post_stream_reports.
#   - streams_count ← Stream WHERE DATE(started_at) = target
#   - classification_at_end ← latest TIH.classification на date
#   - categories (jsonb) ← {game_name → count} по streams on date
#
# Idempotent: UPSERT через unique (channel_id, date). Concurrent worker safety
# handled by AggregationWorker's pg_advisory_lock (ADR §4.3).
#
# Philosophy-v2 simplification (TASK-A1): removed deferred-fields update pipeline
# (discovery_phase_score / follower_ccv_coupling_r / is_best/worst_stream_day) —
# corresponding analysis services удалены (Phase 1a) и schema columns dropped
# (FR-035, Phase 1b migrations).

module Trends
  module Aggregation
    class DailyBuilder
      # schema_version bumped для breaking changes response shape (ADR §4.12).
      SCHEMA_VERSION = TrendsDailyAggregate::SUPPORTED_SCHEMA_VERSIONS.max

      def self.call(channel_id, date)
        new(channel_id, date).call
      end

      def initialize(channel_id, date)
        @channel_id = channel_id
        @date = date.is_a?(String) ? Date.parse(date) : date
      end

      def call
        core_upsert
      end

      private

      def core_upsert
        day_start = @date.beginning_of_day
        day_end = @date.end_of_day

        streams_on_date = Stream
          .for_channel(@channel_id)
          .where(started_at: day_start..day_end)

        tih_on_date = TrustIndexHistory
          .for_channel(@channel_id)
          .where(calculated_at: day_start..day_end)

        attributes = build_attributes(streams_on_date, tih_on_date)
        TrendsDailyAggregate.upsert(attributes, unique_by: %i[channel_id date])
      end

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

      # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv columns dropped from
      # streams. CCV stats для ENDED streams живут в post_stream_reports.
      # Daily aggregates считаются за прошлые дни → все streams ended → каждый имеет PSR.
      # Streams без PSR (rare race condition) исключаются автоматически inner JOIN.
      def ccv_aggregates(streams)
        stats = streams
          .joins("INNER JOIN post_stream_reports ON post_stream_reports.stream_id = streams.id")
          .where.not(post_stream_reports: { ccv_avg: nil })
          .pick(
            Arel.sql("AVG(post_stream_reports.ccv_avg)"),
            Arel.sql("MAX(post_stream_reports.ccv_peak)")
          )
        return { ccv_avg: nil, ccv_peak: nil } if stats.nil?

        {
          ccv_avg: stats[0]&.to_i,
          ccv_peak: stats[1]&.to_i
        }
      end

      def categories_breakdown(streams)
        streams.where.not(game_name: nil).group(:game_name).count
      end

      def latest_classification(tih)
        tih.order(calculated_at: :desc).pick(:classification)
      end
    end
  end
end
