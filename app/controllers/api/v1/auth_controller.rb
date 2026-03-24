# frozen_string_literal: true

module Api
  module V1
    class AuthController < ApplicationController
      skip_before_action :verify_authenticity_token

      # FR-001: POST /api/v1/auth/twitch
      def twitch
        oauth = Auth::TwitchOauth.new
        result = oauth.authorize_url

        # Store code_verifier in Rails cache (keyed by state)
        Rails.cache.write("pkce:#{result[:state]}", result[:code_verifier], expires_in: 10.minutes)

        render json: { redirect_url: result[:redirect_url], state: result[:state] }
      end

      # FR-002: GET /api/v1/auth/twitch/callback
      def twitch_callback
        state = params[:state]
        code = params[:code]
        error = params[:error]

        # EC#1: User denied OAuth
        if error.present?
          render json: { error: "TWITCH_AUTH_DENIED", message: error }, status: :unauthorized
          return
        end

        # EC#9: Invalid state (CSRF)
        code_verifier = Rails.cache.read("pkce:#{state}")
        unless code_verifier
          render json: { error: "INVALID_STATE", message: "Invalid or expired state" }, status: :unauthorized
          return
        end

        Rails.cache.delete("pkce:#{state}")

        oauth = Auth::TwitchOauth.new
        user = oauth.callback(code: code, code_verifier: code_verifier)

        session_record = Session.create!(
          user: user,
          token: SecureRandom.hex(32),
          expires_at: 7.days.from_now,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        access_token = Auth::JwtService.encode_access(user.id)
        refresh_token = Auth::JwtService.encode_refresh(user.id)

        render json: {
          access_token: access_token,
          refresh_token: refresh_token,
          expires_in: 3600,
          user: {
            id: user.id,
            username: user.username,
            role: user.role,
            tier: user.tier
          }
        }
      rescue Auth::JwtService::AuthError => e
        render json: { error: "TWITCH_AUTH_FAILED", message: e.message }, status: :unauthorized
      rescue Errno::ECONNREFUSED, HTTP::TimeoutError => e
        render json: { error: "TWITCH_UNAVAILABLE", message: "Twitch API unavailable" }, status: :service_unavailable
      end

      # FR-003: POST /api/v1/auth/refresh
      def refresh
        payload = Auth::JwtService.decode(params[:refresh_token])

        unless payload[:type] == "refresh"
          render json: { error: "INVALID_TOKEN", message: "Not a refresh token" }, status: :unauthorized
          return
        end

        user = User.find(payload[:sub])

        access_token = Auth::JwtService.encode_access(user.id)
        refresh_token = Auth::JwtService.encode_refresh(user.id)

        render json: {
          access_token: access_token,
          refresh_token: refresh_token,
          expires_in: 3600
        }
      rescue Auth::JwtService::AuthError => e
        render json: { error: "INVALID_TOKEN", message: e.message }, status: :unauthorized
      rescue ActiveRecord::RecordNotFound
        render json: { error: "USER_NOT_FOUND" }, status: :unauthorized
      end

      # FR-004: DELETE /api/v1/auth/logout
      def logout
        token = request.headers["Authorization"]&.split(" ")&.last
        return render json: { error: "NO_TOKEN" }, status: :unauthorized unless token

        payload = Auth::JwtService.decode(token)
        user = User.find(payload[:sub])
        user.sessions.where(is_active: true).update_all(is_active: false)

        render json: { status: "logged_out" }
      rescue Auth::JwtService::AuthError, ActiveRecord::RecordNotFound
        render json: { error: "INVALID_TOKEN" }, status: :unauthorized
      end
    end
  end
end
