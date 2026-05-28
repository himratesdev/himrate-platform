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

          # CR iter-3 N4: точечный rescue domain-specific error class (не общий ArgumentError).
          rescue_from PersonalAnalytics::Enrollment::ExtensionSubsPayloadHandler::InvalidSourceError,
            with: :render_invalid_source

          RETRY_PARAM_ALL = "all"
          RETRY_PARAM_VALID = (PvaEnrollmentBackfillState::SOURCE_KEYS + [ RETRY_PARAM_ALL ]).freeze

          # POST /api/v1/me/analytics/cold_start/retry
          # Body: { source: "all" | "source_1" | "source_2" | "source_5" }
          #
          # Wave 1 per-source retry granularity для banner CTAs (FR-016 §11.6 retry path):
          #   - "all" → reset entire state row + re-enqueue EnrollmentBackfillWorker (force=true).
          #   - "source_1" → reset source_1 cell + re-enqueue HelixFollowsBackfillWorker.
          #   - "source_2" → reset source_2 cell + re-enqueue GqlChannelShellBatchWorker.
          #   - "source_5" → reset source_5 cell only (extension-driven; frontend orchestrator
          #                  triggers Apollo walk again на next poll observing pending source_5).
          #
          # Idempotent — repeated POSTs не duplicate jobs (Sidekiq job classes use perform_async
          # с pre-existing state — workers сами check для in_progress and skip).
          def retry_source
            source = params[:source].to_s
            unless RETRY_PARAM_VALID.include?(source)
              render json: { ok: false, error: "InvalidSource",
                message: "source must be one of #{RETRY_PARAM_VALID.join(', ')}" },
                status: :unprocessable_entity
              return
            end

            if source == RETRY_PARAM_ALL
              PersonalAnalytics::Enrollment::StateStore.initiate(user_id: current_user.id, force: true)
              PersonalAnalytics::Enrollment::EnrollmentBackfillWorker.perform_async(current_user.id, true)
              render json: { ok: true, retried: RETRY_PARAM_ALL }
              return
            end

            # Per-source retry — reset source cell to pending + enqueue source-specific worker.
            updated = PersonalAnalytics::Enrollment::StateStore.reset_source(
              user_id: current_user.id, source_key: source
            )
            if updated.nil?
              render json: { ok: false, error: "NoEnrollmentState",
                message: "no enrollment state row exists for user" },
                status: :unprocessable_entity
              return
            end

            worker = retry_worker_for(source)
            worker&.perform_async(current_user.id) if worker

            render json: { ok: true, retried: source }
          end

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

          # Wave 1 retry workers — source_5 = extension-driven (Apollo cache walk via background
          # tab), no backend worker enqueue needed; frontend orchestrator picks up reset state на
          # next poll и triggers Apollo walk through chrome.runtime.sendMessage.
          def retry_worker_for(source)
            case source
            when "source_1" then PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker
            when "source_2" then PersonalAnalytics::Enrollment::GqlChannelShellBatchWorker
            when "source_5" then nil # extension-driven; no backend worker
            end
          end
        end
      end
    end
  end
end
