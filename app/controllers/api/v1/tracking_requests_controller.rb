# frozen_string_literal: true

# TASK-034 FR-025: Request tracking for untracked channels.
# POST /api/v1/channels/:channel_id/request_tracking
# Rate limited: 5 req/hr per user/install_id (rack-attack).

module Api
  module V1
    class TrackingRequestsController < Api::BaseController
      # Pundit skipped: endpoint accepts both authenticated users and guests (extension_install_id).
      # Authorization is implicit — any requester can submit a tracking request.
      skip_after_action :verify_authorized
      before_action :authenticate_user_optional!

      # POST /api/v1/channels/:channel_id/request_tracking
      def create
        unless Flipper.enabled?(:tracking_requests)
          render json: { error: "FEATURE_DISABLED" }, status: :not_found
          return
        end

        channel_login = params[:channel_id].to_s.downcase.strip

        tracking_request = TrackingRequest.new(
          channel_login: channel_login,
          user_id: current_user&.id,
          extension_install_id: request.headers["X-Extension-Install-Id"],
          status: "pending"
        )

        if tracking_request.save
          render json: { status: "accepted", channel_login: channel_login }, status: :created
        else
          if tracking_request.errors.any? { |e| e.type == :already_requested || e.type == :taken }
            render_already_requested(channel_login)
          else
            render json: {
              error: "VALIDATION_ERROR",
              details: tracking_request.errors.full_messages
            }, status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordNotUnique
        # Race condition: DB constraint caught duplicate between validation and insert
        render_already_requested(channel_login)
      end
      private

      def render_already_requested(channel_login)
        render json: {
          error: "ALREADY_REQUESTED",
          message: I18n.t("tracking_requests.errors.already_requested",
            default: "Tracking request already submitted for this channel"),
          channel_login: channel_login
        }, status: :conflict
      end
    end
  end
end
