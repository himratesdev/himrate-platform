# frozen_string_literal: true

# TASK-039 FR-015 + FR-018 (Phase B1a core + Phase B3 deferred extensions):
# Core daily aggregation + analysis service invocations для заполнения deferred полей.
#
# Phase B1a (core fields, on-stream compute):
#   - TI aggregates (avg/std/min/max) ← TrustIndexHistory WHERE calculated_at::date = target
#   - ERV aggregates (avg/min/max %) ← TrustIndexHistory.erv_percent
#   - CCV (avg/peak) ← Stream.avg_ccv / Stream.peak_ccv aggregated по streams on date
#   - streams_count ← Stream WHERE DATE(started_at) = target
#   - classification_at_end ← latest TIH.classification на date
#   - categories (jsonb) ← {game_name → count} по streams on date
#
# Phase B3 deferred (computed post-upsert, separate UPDATE): FR-029/030/032/033.
#   - discovery_phase_score ← Analysis::DiscoveryPhaseDetector (FR-029)
#   - follower_ccv_coupling_r ← Analysis::FollowerCcvCouplingTimeline (FR-030, rolling)
#   - tier_change_on_day ← hs_tier_change_events existence на date
#   - is_best_stream_day / is_worst_stream_day ← Analysis::BestWorstStreamFinder (period 90d)
#   (signal_breakdown jsonb + botted_fraction — остаются B1b anomaly pipeline scope.)
#
# Idempotent: UPSERT через unique (channel_id, date). Concurrent worker safety
# handled by AggregationWorker's pg_advisory_lock (ADR §4.3).

module Trends
  module Aggregation
    class DailyBuilder
      # schema_version bumped для breaking changes response shape (ADR §4.12).
      SCHEMA_VERSION = TrendsDailyAggregate::SUPPORTED_SCHEMA_VERSIONS.max

      # Period для best/worst stream day marking (rolling 90d window back from date).
      BEST_WORST_LOOKBACK_DAYS = 90

      def self.call(channel_id, date)
        new(channel_id, date).call
      end

      def initialize(channel_id, date)
        @channel_id = channel_id
        @date = date.is_a?(String) ? Date.parse(date) : date
      end

      def call
        core_upsert
        populate_deferred_fields
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

      def categories_breakdown(streams)
        streams.where.not(game_name: nil).group(:game_name).count
      end

      def latest_classification(tih)
        tih.order(calculated_at: :desc).pick(:classification)
      end

      # --- Phase B3 deferred population ---
      #
      # Runs after core UPSERT. Uses SQL UPDATE for partition-safe single-row mutation
      # (SET на PK lookup). Each sub-step is isolated — failure in one (e.g.
      # DiscoveryPhaseDetector) не rollback'ит others (best-effort deferred enrichment).
      # Errors logged, worker retries on transient issues.

      def populate_deferred_fields
        channel = Channel.find_by(id: @channel_id)
        return unless channel

        updates = {}
        updates[:tier_change_on_day] = tier_change_on_day?
        updates[:follower_ccv_coupling_r] = compute_coupling_r(channel)
        updates[:discovery_phase_score] = compute_discovery_score(channel)

        best_worst = compute_best_worst(channel)
        updates[:is_best_stream_day] = best_worst[:is_best]
        updates[:is_worst_stream_day] = best_worst[:is_worst]

        TrendsDailyAggregate.where(channel_id: @channel_id, date: @date).update_all(updates)
      rescue StandardError => e
        Rails.logger.warn("[DailyBuilder] deferred fields failed for channel=#{@channel_id} date=#{@date}: #{e.class} #{e.message}")
      end

      def tier_change_on_day?
        HsTierChangeEvent
          .for_channel(@channel_id)
          .where(event_type: "tier_change")
          .where(occurred_at: @date.beginning_of_day..@date.end_of_day)
          .exists?
      end

      def compute_coupling_r(channel)
        result = Trends::Analysis::FollowerCcvCouplingTimeline.call(
          channel: channel, from: @date, to: @date
        )
        entry = result[:timeline].find { |row| row[:date] == @date }
        entry&.dig(:r)
      end

      def compute_discovery_score(channel)
        # Compute once, only when channel is in discovery window. For older channels
        # DiscoveryPhaseDetector returns status=not_applicable, score=nil (no-op).
        result = Trends::Analysis::DiscoveryPhaseDetector.call(channel)
        result[:score]
      end

      def compute_best_worst(channel)
        result = Trends::Analysis::BestWorstStreamFinder.call(
          channel: channel,
          from: (@date - BEST_WORST_LOOKBACK_DAYS.days).beginning_of_day,
          to: @date.end_of_day
        )
        return { is_best: false, is_worst: false } if result[:insufficient_data]

        {
          is_best: result.dig(:best, :date) == @date,
          is_worst: result.dig(:worst, :date) == @date
        }
      end
    end
  end
end
