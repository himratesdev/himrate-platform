# frozen_string_literal: true

# TASK-039 FR-020: Abstract base для attribution adapters per ADR §4.14.
#
# Contract:
#   .call(anomaly) → Hash { source:, confidence:, raw_source_data: } | nil
#     - Hash → anomaly matches this source (Pipeline создаст AnomalyAttribution row)
#     - nil   → anomaly does NOT match (skipped silently)
#
# Subclasses override #build_attribution(anomaly) protected method. confidence
# в 0..1 range. source должен существовать в AttributionSource.known_sources
# (validated на AnomalyAttribution save).
#
# Design rationale:
#   - Abstract class, не mixin — adapter может иметь state (config cache,
#     threshold lookups) и instance helpers без polluting host class.
#   - Class method .call для симметричного dispatch (Pipeline iterates
#     source.adapter_class.call(anomaly)) — matches existing service pattern.

module Trends
  module Attribution
    class BaseAdapter
      # CR N-5: custom error name (не shadowing Ruby builtin NotImplementedError < ScriptError).
      class ImplementationRequired < StandardError; end

      def self.call(anomaly)
        new.call(anomaly)
      end

      def call(anomaly)
        attribution = build_attribution(anomaly)
        return nil if attribution.nil?

        validate_attribution!(attribution)
        attribution
      end

      protected

      # Abstract — subclasses must implement.
      # Return Hash { source:, confidence:, raw_source_data: } or nil (no match).
      def build_attribution(_anomaly)
        raise ImplementationRequired,
          "#{self.class.name} must implement #build_attribution(anomaly)"
      end

      private

      # Fail-fast на malformed attribution Hash — catches adapter bugs рано.
      def validate_attribution!(attribution)
        missing = %i[source confidence raw_source_data] - attribution.keys
        raise ArgumentError, "Attribution missing keys: #{missing.join(', ')}" unless missing.empty?

        confidence = attribution[:confidence]
        return if confidence.is_a?(Numeric) && confidence.between?(0, 1)

        raise ArgumentError, "Attribution confidence must be 0..1, got: #{confidence.inspect}"
      end
    end
  end
end
