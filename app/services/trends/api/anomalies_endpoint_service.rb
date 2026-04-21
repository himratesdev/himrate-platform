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
      def initialize(channel:, period:, granularity: nil, severity: nil, attributed_only: false)
        super(channel: channel, period: period, granularity: granularity)
        @severity = severity
        @attributed_only = ActiveModel::Type::Boolean.new.cast(attributed_only)
      end

      def call
        from_ts, to_ts = range
        anomalies = build_anomaly_list(from_ts, to_ts)
        frequency = Trends::Analysis::AnomalyFrequencyScorer.call(channel: channel, from: from_ts, to: to_ts)

        {
          data: {
            channel_id: channel.id,
            period: period,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            total: anomalies.size,
            unattributed_count: anomalies.count { |a| a[:attribution] && a[:attribution][:source] == "unattributed" },
            anomalies: anomalies,
            frequency_score: frequency,
            distribution: frequency[:distribution]
          },
          meta: meta
        }
      end

      private

      def build_anomaly_list(from_ts, to_ts)
        scope = base_scope(from_ts, to_ts)
        scope = filter_by_severity(scope) if @severity

        scope_with_attr = scope.includes(:anomaly_attributions)
        rows = scope_with_attr.order(timestamp: :desc).to_a

        rows = filter_attributed(rows) if @attributed_only
        rows.map { |anomaly| row_for(anomaly) }
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

      def filter_attributed(rows)
        rows.reject do |anomaly|
          attributions = anomaly.anomaly_attributions
          attributions.empty? || attributions.all? { |a| a.source == "unattributed" }
        end
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
