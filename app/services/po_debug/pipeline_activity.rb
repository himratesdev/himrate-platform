# frozen_string_literal: true

module PoDebug
  # Block 2 — Pipeline writes rate (rolling 5min) for PO's current live stream.
  #
  # v0.1 Hot-Lite: STUB. v1.0 fills with rates for TIH, PerUserBotScore,
  # CcvSnapshot, ChattersSnapshot, FollowerSnapshot, StreamerReputation,
  # StreamFeatureVector + latest values per source.
  class PipelineActivity
    def self.call
      new.call
    end

    def call
      {
        stub: true,
        message: "Coming in v1.0 (full pipeline writes rate + latest values per source).",
        planned_sources: %w[TrustIndexHistory PerUserBotScore CcvSnapshot ChattersSnapshot FollowerSnapshot StreamerReputation StreamFeatureVector]
      }
    end
  end
end
