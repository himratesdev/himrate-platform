# frozen_string_literal: true

module Api
  module V1
    class AuthEventsController < Api::BaseController
      # Public endpoint — anonymous users send events too
      before_action :authenticate_user_optional!
      skip_after_action :verify_authorized

      def create
        event = AuthEvent.new(auth_event_params)
        event.user = current_user
        event.ip_address = request.remote_ip
        event.user_agent = request.user_agent
        event.created_at = Time.current

        if event.save
          check_consecutive_failures(event) if event.result == "failure"
          render json: { status: "ok" }, status: :created
        else
          render json: { error: "invalid_event" }, status: :unprocessable_entity
        end
      end

      private

      def auth_event_params
        permitted = params.permit(:provider, :result, :error_type, :extension_version)
        permitted[:metadata] = params[:metadata].permit! if params[:metadata].present?
        permitted
      end

      def check_consecutive_failures(event)
        ip = event.ip_address
        recent_failures = AuthEvent.failures.recent(10.minutes).by_ip(ip).count

        return unless recent_failures >= 2

        Rails.logger.warn(
          "Auth alert: #{recent_failures} consecutive failures from #{ip} " \
          "in 10min (provider=#{event.provider}, error=#{event.error_type})"
        )

        # Future: Telegram alert via NotificationService (TASK-044)
        # For now: N8N webhook picks up from Rails logs
      end
    end
  end
end
