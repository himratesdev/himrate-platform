# frozen_string_literal: true

module Api
  module V1
    class AuthController < Api::BaseController
      # FR-001: POST /api/v1/auth/twitch
      def twitch
        oauth = Auth::TwitchOauth.new
        result = oauth.authorize_url

        Rails.cache.write("pkce:#{result[:state]}", result[:code_verifier], expires_in: 10.minutes)

        render json: { redirect_url: result[:redirect_url], state: result[:state] }
      end

      # FR-002: GET /api/v1/auth/twitch/callback
      def twitch_callback
        state = params[:state]
        code = params[:code]
        error = params[:error]

        if error.present?
          render json: { error: "TWITCH_AUTH_DENIED", message: error }, status: :unauthorized
          return
        end

        code_verifier = Rails.cache.read("pkce:#{state}")
        unless code_verifier
          render json: { error: "INVALID_STATE", message: "Invalid or expired state" }, status: :unauthorized
          return
        end

        Rails.cache.delete("pkce:#{state}")

        oauth = Auth::TwitchOauth.new
        user = oauth.callback(code: code, code_verifier: code_verifier)

        Session.create!(
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
            email: user.email,
            role: user.role,
            tier: user.tier
          }
        }
      rescue ActiveRecord::RecordNotUnique
        render json: { error: "EMAIL_ALREADY_EXISTS", message: "This email is registered with another provider" }, status: :conflict
      rescue Auth::AuthError => e
        Rails.logger.error("Auth failed: #{e.class} #{e.message}")
        render json: { error: "TWITCH_AUTH_FAILED", message: e.message }, status: :unauthorized
      rescue Errno::ECONNREFUSED, HTTP::TimeoutError => e
        Rails.logger.error("Twitch API unavailable: #{e.class} #{e.message}")
        render json: { error: "TWITCH_UNAVAILABLE", message: "Twitch API unavailable" }, status: :service_unavailable
      end

      # TASK-007: POST /api/v1/auth/google
      def google
        oauth = Auth::GoogleOauth.new
        result = oauth.authorize_url

        Rails.cache.write("google_state:#{result[:state]}", "valid", expires_in: 10.minutes)

        render json: { redirect_url: result[:redirect_url], state: result[:state] }
      end

      # TASK-007: GET /api/v1/auth/google/callback
      def google_callback
        state = params[:state]
        code = params[:code]
        error = params[:error]

        if error.present?
          render json: { error: "GOOGLE_AUTH_DENIED", message: error }, status: :unauthorized
          return
        end

        unless Rails.cache.read("google_state:#{state}")
          render json: { error: "INVALID_STATE", message: "Invalid or expired state" }, status: :unauthorized
          return
        end

        Rails.cache.delete("google_state:#{state}")

        oauth = Auth::GoogleOauth.new
        user = oauth.callback(code: code)

        Session.create!(
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
            email: user.email,
            role: user.role,
            tier: user.tier
          }
        }
      rescue ActiveRecord::RecordNotUnique
        render json: { error: "EMAIL_ALREADY_EXISTS", message: "This email is registered with another provider" }, status: :conflict
      rescue Auth::AuthError => e
        Rails.logger.error("Google auth failed: #{e.class} #{e.message}")
        render json: { error: "GOOGLE_AUTH_FAILED", message: e.message }, status: :unauthorized
      rescue Errno::ECONNREFUSED, HTTP::TimeoutError => e
        Rails.logger.error("Google API unavailable: #{e.class} #{e.message}")
        render json: { error: "GOOGLE_UNAVAILABLE", message: "Google API unavailable" }, status: :service_unavailable
      end

      # FR-003: POST /api/v1/auth/refresh
      def refresh
        token = params[:refresh_token]
        return render json: { error: "MISSING_TOKEN" }, status: :unauthorized if token.blank?

        payload = Auth::JwtService.decode(token)

        unless payload[:type] == "refresh"
          render json: { error: "INVALID_TOKEN", message: "Not a refresh token" }, status: :unauthorized
          return
        end

        user = User.find(payload[:sub])

        access_token = Auth::JwtService.encode_access(user.id)
        new_refresh = Auth::JwtService.encode_refresh(user.id)

        render json: { access_token: access_token, refresh_token: new_refresh, expires_in: 3600 }
      rescue Auth::AuthError => e
        Rails.logger.error("Token refresh failed: #{e.class} #{e.message}")
        render json: { error: "INVALID_TOKEN", message: e.message }, status: :unauthorized
      rescue ActiveRecord::RecordNotFound
        Rails.logger.error("Token refresh: user not found")
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
      rescue Auth::AuthError, ActiveRecord::RecordNotFound => e
        Rails.logger.error("Logout failed: #{e.class} #{e.message}")
        render json: { error: "INVALID_TOKEN" }, status: :unauthorized
      end
    end
  end
end
