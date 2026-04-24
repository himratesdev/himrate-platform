# frozen_string_literal: true

# TASK-039 Visual QA: creates AnomalyAttribution rows для seeded Anomaly events.
# Feeds M4 anomaly card attribution field — без этого UI показывает "unattributed"
# fallback для всех anomalies.
#
# Pattern: каждая anomaly гets 1-2 attributions (one 'unattributed' always + one real
# source для half). Mirrors real pipeline behavior (Trends::Attribution::Pipeline).
#
# Idempotent via (anomaly_id, source) unique constraint.

module Trends
  module VisualQa
    class AnomalyAttributionSeeder
      REAL_SOURCES_CYCLE = %w[raid_organic platform_cleanup raid_bot].freeze

      # Canonical AttributionSource rows (normally seeded via migration 100007).
      # В test env maintain_test_schema uses structure.sql → migrations don't run →
      # sources missing. Self-sufficient seeder ensures rows present before attribution.
      CANONICAL_SOURCES = {
        "raid_organic" => "Trends::Attribution::RaidOrganicAdapter",
        "raid_bot" => "Trends::Attribution::RaidBotAdapter",
        "platform_cleanup" => "Trends::Attribution::PlatformCleanupAdapter",
        "unattributed" => "Trends::Attribution::UnattributedFallback"
      }.freeze

      def self.seed(anomalies:)
        new(anomalies: anomalies).seed
      end

      def initialize(anomalies:)
        @anomalies = anomalies
      end

      def seed
        ensure_attribution_sources!

        attributions = []
        @anomalies.each_with_index do |anomaly, idx|
          # Half anomalies attributed к real source, other half остаётся unattributed fallback only.
          if idx.even?
            source = REAL_SOURCES_CYCLE[(idx / 2) % REAL_SOURCES_CYCLE.size]
            attributions << upsert_attribution(
              anomaly,
              source: source,
              confidence: 0.85,
              raw_source_data: { source: "visual_qa_seeder", profile_idx: idx }
            )
          end

          # Always: unattributed fallback row (mirrors production pipeline).
          attributions << upsert_attribution(
            anomaly,
            source: "unattributed",
            confidence: 1.0,
            raw_source_data: { fallback: true }
          )
        end
        attributions
      end

      private

      def upsert_attribution(anomaly, source:, confidence:, raw_source_data:)
        AnomalyAttribution.find_or_create_by!(anomaly_id: anomaly.id, source: source) do |a|
          a.confidence = confidence
          a.raw_source_data = raw_source_data
          a.attributed_at = anomaly.timestamp + 1.minute
        end
      end

      def ensure_attribution_sources!
        CANONICAL_SOURCES.each_with_index do |(source, adapter), idx|
          AttributionSource.find_or_create_by!(source: source) do |s|
            s.enabled = true
            s.priority = (idx + 1) * 10
            s.display_label_en = source.humanize
            s.display_label_ru = source.humanize
            s.adapter_class_name = adapter
          end
        end
      end
    end
  end
end
