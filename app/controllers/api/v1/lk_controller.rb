# frozen_string_literal: true

module Api
  module V1
    # SaaS ЛК shell: visibility gate + launch-notify capture. Public (auth optional): the frontend
    # calls /lk/status on every ЛК load to route login (70) / flag-off (71) / dashboard.
    class LkController < Api::BaseController
      skip_after_action :verify_authorized
      before_action :authenticate_user_optional!

      # GET /api/v1/lk/status — single routing source for the ЛК shell.
      def status
        # OPEN-HOUSE guest mode: bind a session-less visitor to the shared demo account so EVERY
        # page (browse and personal alike) renders instead of bouncing to /login. The client reads
        # `guest_access` to know it is a demo session — the pages themselves need no special case.
        open_house_guest_session! if current_user.nil?

        render json: {
          saas_lk_live: Flipper.enabled?(:saas_lk_live, current_user),
          authenticated: current_user.present?,
          guest_access: current_user&.demo? || false,
          roles: current_user&.roles || [],
          email: current_user&.email
        }
      end

      # POST /api/v1/lk/notify — capture email for launch notification (flag-off, screen 71).
      def notify
        NotifyRequest.capture(email: notify_params[:email], user: current_user)
        render json: { subscribed: true }
      rescue ActiveRecord::RecordInvalid
        render json: { error: { code: "INVALID_EMAIL" } }, status: :unprocessable_entity
      end

      private

      def notify_params
        params.permit(:email)
      end
    end
  end
end
