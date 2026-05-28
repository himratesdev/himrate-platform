# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 (FR-016): cold-start enrollment state + extension payload endpoints.
# Two routes:
#   - GET  /api/v1/me/analytics/cold_start/state           — frontend polling (5s cadence)
#   - POST /api/v1/me/analytics/cold_start/subs_payload    — extension sources #4 / #5 ingest
#
# Auth: JWT Bearer (current_user). Pundit ownership only — NO paywall (PVA all-free per BR-002 v1.1).
module Api
  module V1
    module Me
      module Analytics
        class ColdStartController < Api::BaseController
          before_action :authenticate_user!
          # PVA all-free — ownership через JWT (current_user), нет Pundit policy paywall.
          skip_after_action :verify_authorized

          rescue_from ArgumentError, with: :render_invalid_source

          # GET /api/v1/me/analytics/cold_start/state
          def state
            state = PersonalAnalytics::Enrollment::StateStore.read_state(user_id: current_user.id)
            if state.nil?
              render json: { overall_status: "not_started", sources: {} }
              return
            end

            render json: {
              overall_status: state["overall_status"],
              oauth_linked_at: state["oauth_linked_at"],
              completed_at: state["completed_at"],
              failed_sources: state["failed_sources"] || [],
              sources: PvaEnrollmentBackfillState::SOURCE_KEYS.each_with_object({}) { |k, h| h[k] = state[k] }
            }
          end

          # POST /api/v1/me/analytics/cold_start/subs_payload
          # Body: { source: 4|5, subscriptions: [{...}], captured_at: ISO-8601 }
          SUBS_PAYLOAD_MAX = 5_000

          def subs_payload
            payload = params.permit(:source, :captured_at,
              subscriptions: [ :channel_twitch_id, :channel_login, :channel_display_name,
                              :tier, :cumulative_months, :started_at, :anniversary_at ]).to_h

            # CR iter-1 N1: cap payload size to prevent puma worker stall + WAL bloat.
            # Twitch UI maxes around few thousand subs even for power users.
            if Array.wrap(payload["subscriptions"]).size > SUBS_PAYLOAD_MAX
              render json: { ok: false, error: "PayloadTooLarge",
                message: "subscriptions exceeds #{SUBS_PAYLOAD_MAX}" },
                status: :payload_too_large
              return
            end

            result = PersonalAnalytics::Enrollment::ExtensionSubsPayloadHandler.call(
              user_id: current_user.id, payload: payload
            )

            if result.error_class
              render json: { ok: false, error: result.error_class }, status: :unprocessable_entity
            else
              render json: { ok: true, rows_affected: result.rows_affected }
            end
          end

          private

          def render_invalid_source(error)
            render json: { ok: false, error: "InvalidSource", message: error.message },
              status: :unprocessable_entity
          end
        end
      end
    end
  end
end
