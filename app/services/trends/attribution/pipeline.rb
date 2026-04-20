# frozen_string_literal: true

# TASK-039 FR-019: Attribution pipeline orchestrator. Iterates enabled
# AttributionSource records ordered by priority ASC (raid_organic=10 first,
# unattributed=999 last — ADR §4.14 extensible адаптеров).
#
# Per source: resolve adapter class (AttributionSource.adapter_class via
# constantize — DB-driven dispatch, future adapters = new AttributionSource row
# + adapter class, zero schema changes).
#
# Multiple matches allowed: один anomaly может иметь raid_bot + platform_cleanup
# attributions одновременно (UNIQUE constraint — anomaly_id + source composite).
#
# UPSERT semantics: idempotent re-run (backfill rake, retry) = clean update
# без duplicate rows.
#
# Returns Array of created/updated AnomalyAttribution records (may be empty if
# all enabled adapters returned nil — theoretically impossible с UnattributedFallback
# always matching, но defensive).

module Trends
  module Attribution
    class Pipeline
      def self.call(anomaly)
        new(anomaly).call
      end

      def initialize(anomaly)
        @anomaly = anomaly
      end

      def call
        results = []

        AttributionSource.pipeline.find_each do |source|
          attribution_data = invoke_adapter(source)
          next if attribution_data.nil?

          attribution = upsert_attribution(attribution_data)
          results << attribution if attribution
        end

        results
      end

      private

      def invoke_adapter(source)
        source.adapter_class.call(@anomaly)
      rescue AttributionSource::AdapterNotFound => e
        Rails.logger.warn(
          "Trends::Attribution::Pipeline: adapter missing для source=#{source.source} " \
          "anomaly=#{@anomaly.id} — #{e.message}"
        )
        nil
      rescue StandardError => e
        # Adapter bug не должен break pipeline — log и continue к next adapter.
        Rails.logger.error(
          "Trends::Attribution::Pipeline: #{source.adapter_class_name} raised " \
          "#{e.class}: #{e.message} для anomaly=#{@anomaly.id}"
        )
        nil
      end

      def upsert_attribution(data)
        attribution = AnomalyAttribution.find_or_initialize_by(
          anomaly_id: @anomaly.id,
          source: data[:source]
        )
        attribution.confidence = data[:confidence]
        attribution.raw_source_data = data[:raw_source_data]
        attribution.attributed_at = Time.current
        attribution.save!
        attribution
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn(
          "Trends::Attribution::Pipeline: attribution validation failed anomaly=#{@anomaly.id} " \
          "source=#{data[:source]}: #{e.message}"
        )
        nil
      end
    end
  end
end
