# frozen_string_literal: true

# TASK-032 FR-012 + ADR: Real-time TI/ERV updates via Action Cable.
# Extension subscribes to channel_id. SignalComputeWorker broadcasts after each compute.
# Tier-scoped: Guest gets headline, Free gets drill_down during live/18h, Premium gets full.

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

  # Called by SignalComputeWorker after TI computation:
  # TrustChannel.broadcast_to(channel, payload)
  def self.broadcast_trust_update(channel, trust_index_history)
    erv_data = TrustIndex::ErvCalculator.compute(
      ti_score: trust_index_history.trust_index_score.to_f,
      ccv: trust_index_history.ccv.to_i,
      confidence: trust_index_history.confidence.to_f
    )

    payload = {
      type: "trust_update",
      channel_id: channel.id,
      ti_score: trust_index_history.trust_index_score.to_f,
      classification: trust_index_history.classification,
      erv_percent: trust_index_history.erv_percent&.to_f,
      erv_count: erv_data[:erv_count],
      erv_label: erv_data[:label],
      erv_label_color: erv_data[:label_color],
      confidence: trust_index_history.confidence&.to_f,
      cold_start_status: trust_index_history.cold_start_status,
      signal_breakdown: trust_index_history.signal_breakdown,
      ccv: trust_index_history.ccv,
      calculated_at: trust_index_history.calculated_at.iso8601,
      timestamp: Time.current.iso8601
    }

    broadcast_to(channel, payload)
  end
end
