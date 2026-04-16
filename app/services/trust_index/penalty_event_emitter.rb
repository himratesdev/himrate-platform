# frozen_string_literal: true

# TASK-038 AR-11: Emit RehabilitationPenaltyEvent when TI transitions below 50,
# resolve active event when channel reaches required clean streams.
# Called synchronously by TrustIndex::Engine after each TI computation.

module TrustIndex
  class PenaltyEventEmitter
    PENALTY_THRESHOLD = 50
    DEFAULT_REQUIRED_CLEAN_STREAMS = 15

    def self.call(channel:, stream:, ti_score:)
      new.call(channel: channel, stream: stream, ti_score: ti_score)
    end

    def call(channel:, stream:, ti_score:)
      return if ti_score.nil?

      active_event = RehabilitationPenaltyEvent.latest_active_for(channel.id)

      if ti_score < PENALTY_THRESHOLD
        emit_penalty_event(channel, stream, ti_score) unless active_event
      elsif active_event
        maybe_resolve_event(active_event, channel, stream)
      end
    end

    private

    def emit_penalty_event(channel, stream, ti_score)
      initial_penalty = [ PENALTY_THRESHOLD - ti_score.to_f, 0.01 ].max.round(2)
      RehabilitationPenaltyEvent.create!(
        channel: channel,
        applied_stream: stream,
        initial_penalty: initial_penalty,
        required_clean_streams: required_clean_streams,
        applied_at: Time.current
      )
      Rails.logger.info(
        "PenaltyEventEmitter: channel #{channel.id} — penalty applied " \
        "ti=#{ti_score.round(1)} initial_penalty=#{initial_penalty}"
      )
    end

    def maybe_resolve_event(event, channel, _stream)
      clean_streams = count_clean_streams_since(channel, event.applied_at)
      return unless clean_streams >= event.required_clean_streams

      event.update!(resolved_at: Time.current, clean_streams_at_resolve: clean_streams)
      Rails.logger.info(
        "PenaltyEventEmitter: channel #{channel.id} — penalty resolved " \
        "clean_streams=#{clean_streams}"
      )
    end

    # M6 fix: only count streams started AFTER penalty applied_at.
    # Prevents pre-penalty TI refreshes from polluting the counter.
    def count_clean_streams_since(channel, since)
      clean_stream_ids = Stream
        .where(channel_id: channel.id)
        .where("started_at > ?", since)
        .pluck(:id)

      return 0 if clean_stream_ids.empty?

      TrustIndexHistory
        .where(channel_id: channel.id, stream_id: clean_stream_ids)
        .where("trust_index_score >= ?", PENALTY_THRESHOLD)
        .distinct
        .count(:stream_id)
    end

    def required_clean_streams
      SignalConfiguration
        .where(signal_type: "recommendation", category: "default", param_name: "rehab_required_clean_streams")
        .pick(:param_value)&.to_i || DEFAULT_REQUIRED_CLEAN_STREAMS
    end
  end
end
