# frozen_string_literal: true

# TASK-110 FR-021..025: Cross-device sync API endpoints.
# POST /sync/events — extension push batch of viewing events (idempotency via event_hash UNIQUE).
# GET /sync/snapshot — extension pull aggregated state + dark_period_markers (FR-024).

module Api
  module V1
    class SyncController < Api::BaseController
      before_action :authenticate_user!

      MAX_BATCH_SIZE = 100

      # POST /api/v1/sync/events
      def push
        authorize User, :push?, policy_class: SyncPolicy

        events = Array(params[:events]).first(MAX_BATCH_SIZE)
        return render(json: { error: "invalid_events", message: "events array required" }, status: :bad_request) if events.empty?

        SyncEventBatchWorker.perform_async(current_user.id, events.map(&:to_unsafe_h))

        # S-8 (CR): honest async contract — worker применяет insert_all on_conflict_do_nothing,
        # реальный accepted ≤ submitted (duplicates skipped FR-023). НЕ обещаем accepted/errors
        # до worker execution. Frontend understands queued=true → poll snapshot для confirmation.
        render json: { submitted: events.size, queued: true }, status: :accepted
      end

      # GET /api/v1/sync/snapshot
      def snapshot
        authorize User, :pull?, policy_class: SyncPolicy

        recent_events = SyncEvent.for_user(current_user).recent(100)
        dark_periods = DarkPeriodMarker.for_user(current_user).recent(10)

        render json: {
          meta: {
            last_sync_at: recent_events.first&.synced_at&.iso8601,
            user_id: current_user.id
          },
          recent_events: recent_events.map { |e| serialize_event(e) },
          dark_period_markers: dark_periods.map { |d| serialize_dark_period(d) }
        }
      end

      private

      def serialize_event(event)
        {
          event_type: event.event_type,
          payload: event.payload,
          synced_at: event.synced_at.iso8601
        }
      end

      def serialize_dark_period(marker)
        {
          period_start: marker.period_start.iso8601,
          period_end: marker.period_end&.iso8601,
          n_streams: marker.n_streams,
          m_channels: marker.m_channels
        }
      end
    end
  end
end
