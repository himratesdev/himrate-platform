# frozen_string_literal: true

# TASK-039 FR-004: GET /api/v1/channels/:id/trends/anomalies — M4 Anomaly Events.
# Response per SRS §4.3 (extended): list + frequency_score + distribution + attribution.
#
# Filter params:
#   - severity: "high" | "medium" | "low" (derived from confidence threshold in SignalConfig)
#   - attributed_only: "true" → exclude anomalies с source='unattributed'

module Trends
  module Api
    class AnomaliesEndpointService < BaseEndpointService
      DEFAULT_PAGE = 1
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE = 200 # hard cap — CR S-1: unbounded list protection на 365d heavy channels.

      def initialize(channel:, period:, granularity: nil, severity: nil, attributed_only: false, page: nil, per_page: nil, user: nil)
        super(channel: channel, period: period, granularity: granularity, user: user)
        @severity = severity
        @attributed_only = ActiveModel::Type::Boolean.new.cast(attributed_only)
        @page = [ (page || DEFAULT_PAGE).to_i, 1 ].max
        @per_page = [ (per_page || DEFAULT_PER_PAGE).to_i, MAX_PER_PAGE ].min
        @per_page = DEFAULT_PER_PAGE if @per_page <= 0
      end

      def call
        from_ts, to_ts = range
        list_result = build_anomaly_list(from_ts, to_ts)
        frequency = Trends::Analysis::AnomalyFrequencyScorer.call(channel: channel, from: from_ts, to: to_ts)

        {
          data: {
            channel_id: channel.id,
            period: period,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            total: list_result[:total],
            unattributed_count: list_result[:rows].count { |a| a[:attribution] && a[:attribution][:source] == "unattributed" },
            anomalies: list_result[:rows],
            pagination: {
              page: @page,
              per_page: @per_page,
              total_pages: list_result[:total_pages],
              has_next: @page < list_result[:total_pages]
            },
            frequency_score: frequency,
            distribution: frequency[:distribution]
          },
          meta: meta
        }
      end

      private

      # CR S-1: paginated + bounded. CR PG W-3: attributed filter применяется в SQL
      # (subquery EXISTS), чтобы total + total_pages + has_next отражали filtered
      # count accurately. Избегаем JOIN duplicates через subquery pattern.
      def build_anomaly_list(from_ts, to_ts)
        scope = base_scope(from_ts, to_ts)
        scope = filter_by_severity(scope) if @severity
        scope = filter_attributed_sql(scope) if @attributed_only

        total = scope.count
        total_pages = [ (total.to_f / @per_page).ceil, 1 ].max

        paged = scope
          .includes(:anomaly_attributions)
          .order(timestamp: :desc)
          .limit(@per_page)
          .offset((@page - 1) * @per_page)
          .to_a

        {
          rows: paged.map { |anomaly| row_for(anomaly) },
          total: total,
          total_pages: total_pages
        }
      end

      def base_scope(from_ts, to_ts)
        Anomaly
          .joins(:stream)
          .where(streams: { channel_id: channel.id })
          .where(timestamp: from_ts..to_ts)
      end

      def filter_by_severity(scope)
        threshold = severity_to_confidence_threshold(@severity)
        return scope if threshold.nil?

        scope.where("confidence >= ?", threshold)
      end

      def severity_to_confidence_threshold(severity)
        # High/medium/low mapping via SignalConfig (build-for-years, admin-tunable).
        # Re-use existing anomaly_freq.min_confidence_threshold для medium; compute high/low вокруг.
        medium = SignalConfiguration.value_for("trends", "anomaly_freq", "min_confidence_threshold").to_f
        case severity.to_s
        when "high" then medium + 0.3  # e.g. 0.7+
        when "medium" then medium       # e.g. 0.4+
        when "low" then 0.0             # all (включая low confidence)
        end
      end

      # CR PG W-3: SQL-level filter — anomaly включается если EXISTS хотя бы одна
      # attribution с source != 'unattributed'. Subquery избегает JOIN row duplication
      # (anomaly с N attributions не умножается на N в результате).
      #
      # Семантически тождественно старому in-memory filter_attributed (removed): anomaly
      # без attributions OR со ВСЕМИ unattributed = not shown.
      # Reuse AnomalyAttribution.attributed scope (source != 'unattributed').
      # Subquery → zero JOIN duplication (anomaly с N attributions → 1 row в результате).
      def filter_attributed_sql(scope)
        scope.where(id: AnomalyAttribution.attributed.select(:anomaly_id))
      end

      def row_for(anomaly)
        highest_confidence_attribution = anomaly.anomaly_attributions.max_by { |a| a.confidence.to_f }

        {
          anomaly_id: anomaly.id,
          date: anomaly.timestamp.iso8601,
          stream_id: anomaly.stream_id,
          type: anomaly.anomaly_type,
          cause: anomaly.cause,
          confidence: anomaly.confidence&.to_f&.round(3),
          ccv_impact: anomaly.ccv_impact,
          details: anomaly.details,
          attribution: highest_confidence_attribution ? attribution_hash(highest_confidence_attribution) : nil
        }
      end

      def attribution_hash(attribution)
        {
          source: attribution.source,
          confidence: attribution.confidence.to_f.round(3),
          attributed_at: attribution.attributed_at.iso8601,
          raw_source_data: attribution.raw_source_data
        }
      end
    end
  end
end
