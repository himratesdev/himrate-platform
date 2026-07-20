# frozen_string_literal: true

# TASK-032 FR-012: Action Cable channel for stream lifecycle events (stream_ended /
# stream_expiring via PostStreamNotificationService.broadcast_to). Live TI/ERV updates flow
# through SignalComputeWorker#publish_update (raw Redis pub/sub), NOT ActionCable.
# PR3b (T1-074, B5): the dead `broadcast_trust_update` (v1-field reader, zero in-code callers —
# its "Called by SignalComputeWorker" comment was stale) was DELETED rather than fake-ported.

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
end
