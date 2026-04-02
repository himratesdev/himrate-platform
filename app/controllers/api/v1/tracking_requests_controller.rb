# frozen_string_literal: true

# TASK-034 FR-025: Request tracking for untracked channels.
# POST /api/v1/channels/:channel_id/request_tracking
# Rate limited: 5 req/hr per user/install_id (rack-attack).

module Api
  module V1
    class TrackingRequestsController < Api::BaseController
      skip_after_action :verify_authorized
      before_action :authenticate_user_optional!

      # POST /api/v1/channels/:channel_id/request_tracking
      def create
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
            render json: {
              error: "ALREADY_REQUESTED",
              message: I18n.t("tracking_requests.errors.already_requested",
                default: "Tracking request already submitted for this channel")
            }, status: :conflict
          else
            render json: {
              error: "VALIDATION_ERROR",
              details: tracking_request.errors.full_messages
            }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
