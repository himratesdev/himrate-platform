# frozen_string_literal: true

# TASK-032 FR-012 + ADR + CR #2: Real-time TI/ERV via Action Cable.
# CR #2: Broadcast ONLY headline-safe data. Clients fetch tier-scoped details via REST.
# This prevents information leak — Guest/Free don't receive Premium-only signal_breakdown.

class TrustChannel < ApplicationCable::Channel
  def subscribed
    channel_record = Channel.find_by(id: params[:channel_id]) ||
                     Channel.find_by(login: params[:channel_id])

    if channel_record
      stream_for channel_record
      @channel_record = channel_record
    else
      reject
    end
  end

  def unsubscribed
    stop_all_streams
  end

  # Called by SignalComputeWorker after TI computation.
  # CR #2: Broadcasts HEADLINE-ONLY data (safe for all tiers).
  # Clients that need drill_down/full data fetch via GET /trust after receiving update.
  def self.broadcast_trust_update(channel, trust_index_history)
    erv_data = TrustIndex::ErvCalculator.compute(
      ti_score: trust_index_history.trust_index_score.to_f,
      ccv: trust_index_history.ccv.to_i,
      confidence: trust_index_history.confidence.to_f
    )

    # Headline-safe payload only — no signal_breakdown, no reputation, no rehabilitation
    payload = {
      type: "trust_update",
      channel_id: channel.id,
      ti_score: trust_index_history.trust_index_score.to_f,
      classification: trust_index_history.classification,
      erv_percent: trust_index_history.erv_percent&.to_f&.clamp(0.0, 100.0),
      erv_count: erv_data[:erv_count],
      erv_label: erv_data[:label],
      erv_label_color: erv_data[:label_color],
      confidence: trust_index_history.confidence&.to_f,
      cold_start_status: trust_index_history.cold_start_status,
      ccv: trust_index_history.ccv,
      calculated_at: trust_index_history.calculated_at.iso8601,
      timestamp: Time.current.iso8601
    }

    broadcast_to(channel, payload)
  end
end
