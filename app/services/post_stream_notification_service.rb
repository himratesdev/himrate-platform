# frozen_string_literal: true

# TASK-033 FR-006: Action Cable broadcast for stream lifecycle events.
# Broadcasts stream_ended with mini-summary (TI, ERV%, duration) after report generation.
# Used by: PostStreamWorker.

class PostStreamNotificationService
  # FR-006: Broadcast stream_ended via Action Cable (TrustChannel).
  # Includes mini-summary so Extension can show notification without extra API call.
  def self.broadcast_stream_ended(stream, report = nil)
    channel = stream.channel

    payload = {
      type: "stream_ended",
      channel_id: channel.id,
      channel_login: channel.login,
      stream_id: stream.id,
      expires_at: (stream.ended_at + 18.hours).iso8601,
      merged_parts_count: stream.merged_parts_count,
      ti_score: report&.trust_index_final&.to_f,
      erv_percent: report&.erv_percent_final&.to_f,
      duration_ms: stream.duration_ms,
      timestamp: Time.current.iso8601
    }

    TrustChannel.broadcast_to(channel, payload)
  rescue StandardError => e
    Rails.logger.warn("PostStreamNotificationService: broadcast_stream_ended failed — #{e.message}")
  end

  # FR-009: Broadcast stream_expiring warning (1h before 18h window closes).
  def self.broadcast_stream_expiring(stream)
    channel = stream.channel

    payload = {
      type: "stream_expiring",
      channel_id: channel.id,
      channel_login: channel.login,
      stream_id: stream.id,
      expires_at: (stream.ended_at + 18.hours).iso8601,
      timestamp: Time.current.iso8601
    }

    TrustChannel.broadcast_to(channel, payload)
  rescue StandardError => e
    Rails.logger.warn("PostStreamNotificationService: broadcast_stream_expiring failed — #{e.message}")
  end
end
