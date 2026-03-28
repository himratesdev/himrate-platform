# frozen_string_literal: true

module Api
  module V1
    class AuthEventsController < Api::BaseController
      # Public endpoint — no auth required (anonymous users send events too)
      skip_after_action :verify_authorized

      def create
        event = AuthEvent.new(auth_event_params)
        event.user = current_user_optional
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
        params.permit(:provider, :result, :error_type, :extension_version, metadata: {})
      end

      def current_user_optional
        token = request.headers["Authorization"]&.delete_prefix("Bearer ")
        return nil unless token

        Auth::JwtService.decode(token)&.then { |payload| User.find_by(id: payload["sub"]) }
      rescue StandardError
        nil
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
