# frozen_string_literal: true

# TASK-033 FR-006: Action Cable broadcast for stream lifecycle events.
# Broadcasts stream_ended with mini-summary (TI, ERV%, duration) after report generation.
# Used by: PostStreamWorker.

class PostStreamNotificationService
  # FR-006: Broadcast stream_ended via Action Cable (TrustChannel).
  # Includes mini-summary so Extension can show notification without extra API call.
  # PR3b (T1-074, C1): under ti_v2_engine the summary is {erv, erv_interval, band} — ti_score /
  # erv_percent retired (T2 handler reads message.erv / message.erv_interval with cache fallbacks).
  # `tih:` = the stream's FINAL v2 TIH row (PSR has no interval columns); nil-safe.
  def self.broadcast_stream_ended(stream, report = nil, tih: nil)
    channel = stream.channel

    payload = {
      type: "stream_ended",
      channel_id: channel.id,
      channel_login: channel.login,
      stream_id: stream.id,
      expires_at: (stream.ended_at + 18.hours).iso8601,
      merged_parts_count: stream.merged_parts_count,
      # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): stream.duration_ms column dropped —
      # derive via Stream#current_duration_ms (PSR.duration_ms для ended streams).
      duration_ms: stream.current_duration_ms,
      timestamp: Time.current.iso8601
    }

    if ti_v2_engine?
      payload.merge!(
        erv: report&.erv_final,
        erv_interval: tih&.erv_lo ? { lo: tih.erv_lo, hi: tih.erv_hi } : nil,
        band: tih&.band_row ? { row: tih.band_row, color: tih.band_color, sub: tih.band_sub } : nil,
        engine_version: "v2"
      )
    else
      payload.merge!(
        ti_score: report&.trust_index_final&.to_f,
        erv_percent: report&.erv_percent_final&.to_f
      )
    end

    TrustChannel.broadcast_to(channel, payload)
  rescue StandardError => e
    Rails.logger.warn("PostStreamNotificationService: broadcast_stream_ended failed — #{e.message}")
  end

  def self.ti_v2_engine?
    Flipper.enabled?(:ti_v2_engine)
  rescue StandardError
    false
  end
  private_class_method :ti_v2_engine?

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
