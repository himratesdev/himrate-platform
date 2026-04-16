# frozen_string_literal: true

# TASK-038 FR-028 / AR-11: Rehabilitation state tracker.
# Reads from explicit rehabilitation_penalty_events table (not derived).
# Returns { active:, clean_streams:, required:, progress_pct: }.

module TrustIndex
  class RehabilitationTracker
    def self.call(channel)
      active_event = RehabilitationPenaltyEvent.latest_active_for(channel.id)
      return { active: false } unless active_event

      clean_streams = count_clean_streams_since(channel, active_event.applied_at)
      required = active_event.required_clean_streams
      progress_pct = ((clean_streams.to_f / required) * 100).round.clamp(0, 100)

      {
        active: true,
        clean_streams: clean_streams,
        required: required,
        progress_pct: progress_pct,
        applied_at: active_event.applied_at.iso8601,
        initial_penalty: active_event.initial_penalty.to_f
      }
    end

    def self.count_clean_streams_since(channel, since)
      TrustIndexHistory
        .where(channel_id: channel.id)
        .where("calculated_at > ?", since)
        .where("trust_index_score >= ?", 50)
        .distinct
        .count(:stream_id)
    end
  end
end
