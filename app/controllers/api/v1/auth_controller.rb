# frozen_string_literal: true

module Api
  module V1
    class AuthController < Api::BaseController
      skip_after_action :verify_authorized

      # FR-001: POST /api/v1/auth/twitch
      def twitch
        redirect_uri = validated_redirect_uri(ENV.fetch("TWITCH_REDIRECT_URI"))
        return unless redirect_uri

        oauth = Auth::TwitchOauth.new
        result = oauth.authorize_url(redirect_uri: redirect_uri)

        Rails.cache.write(
          "pkce:#{result[:state]}",
          { code_verifier: result[:code_verifier], redirect_uri: redirect_uri },
          expires_in: 10.minutes
        )

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

        cached = Rails.cache.read("pkce:#{state}")
        unless cached.is_a?(Hash)
          render json: { error: "INVALID_STATE", message: I18n.t("auth.errors.invalid_state") }, status: :unauthorized
          return
        end

        Rails.cache.delete("pkce:#{state}")

        oauth = Auth::TwitchOauth.new
        user = oauth.callback(code: code, code_verifier: cached[:code_verifier], redirect_uri: cached[:redirect_uri])

        Session.create!(
          user: user,
          token: SecureRandom.hex(32),
          expires_at: 7.days.from_now,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        access_token = Auth::JwtService.encode_access(user.id)
        refresh_token = Auth::JwtService.encode_refresh(user.id)

        # TASK-113 Δ-1 Wave 1 (FR-016): trigger cold-start enrollment backfill async на
        # successful Twitch OAuth link. Worker idempotent (BR-015: skip if recent <30d).
        # Flag-gated :pva (no-op если flag off).
        if Flipper.enabled?(:pva)
          PersonalAnalytics::Enrollment::EnrollmentBackfillWorker.perform_async(user.id)
        end

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
        Rails.logger.warn("Cross-provider email collision: #{request.path}")
        render json: { error: "EMAIL_ALREADY_EXISTS", message: I18n.t("auth.errors.email_exists") }, status: :conflict
      rescue Auth::AuthError => e
        Rails.logger.error("Auth failed: #{e.class} #{e.message}")
        render json: { error: "TWITCH_AUTH_FAILED", message: I18n.t("auth.errors.twitch_auth_failed") }, status: :unauthorized
      rescue Errno::ECONNREFUSED, HTTP::TimeoutError => e
        Rails.logger.error("Twitch API unavailable: #{e.class} #{e.message}")
        render json: { error: "TWITCH_UNAVAILABLE", message: I18n.t("auth.errors.twitch_unavailable") }, status: :service_unavailable
      end

      # TASK-007: POST /api/v1/auth/google
      def google
        redirect_uri = validated_redirect_uri(ENV.fetch("GOOGLE_REDIRECT_URI"))
        return unless redirect_uri

        oauth = Auth::GoogleOauth.new
        result = oauth.authorize_url(redirect_uri: redirect_uri)

        Rails.cache.write(
          "google_state:#{result[:state]}",
          { redirect_uri: redirect_uri },
          expires_in: 10.minutes
        )

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

        cached = Rails.cache.read("google_state:#{state}")
        unless cached.is_a?(Hash)
          render json: { error: "INVALID_STATE", message: I18n.t("auth.errors.invalid_state") }, status: :unauthorized
          return
        end

        Rails.cache.delete("google_state:#{state}")

        oauth = Auth::GoogleOauth.new
        user = oauth.callback(code: code, redirect_uri: cached[:redirect_uri])

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
        Rails.logger.warn("Cross-provider email collision: #{request.path}")
        render json: { error: "EMAIL_ALREADY_EXISTS", message: I18n.t("auth.errors.email_exists") }, status: :conflict
      rescue Auth::AuthError => e
        Rails.logger.error("Google auth failed: #{e.class} #{e.message}")
        render json: { error: "GOOGLE_AUTH_FAILED", message: I18n.t("auth.errors.google_auth_failed") }, status: :unauthorized
      rescue Errno::ECONNREFUSED, HTTP::TimeoutError => e
        Rails.logger.error("Google API unavailable: #{e.class} #{e.message}")
        render json: { error: "GOOGLE_UNAVAILABLE", message: I18n.t("auth.errors.google_unavailable") }, status: :service_unavailable
      end

      # FR-003: POST /api/v1/auth/refresh
      def refresh
        token = params[:refresh_token]
        return render json: { error: "MISSING_TOKEN", message: I18n.t("auth.errors.missing_token") }, status: :unauthorized if token.blank?

        payload = Auth::JwtService.decode(token)

        unless payload[:type] == "refresh"
          render json: { error: "INVALID_TOKEN", message: I18n.t("auth.errors.not_refresh_token") }, status: :unauthorized
          return
        end

        user = User.find(payload[:sub])

        access_token = Auth::JwtService.encode_access(user.id)
        new_refresh = Auth::JwtService.encode_refresh(user.id)

        render json: { access_token: access_token, refresh_token: new_refresh, expires_in: 3600 }
      rescue Auth::AuthError => e
        Rails.logger.error("Token refresh failed: #{e.class} #{e.message}")
        render json: { error: "INVALID_TOKEN", message: I18n.t("auth.errors.invalid_token") }, status: :unauthorized
      rescue ActiveRecord::RecordNotFound
        Rails.logger.error("Token refresh: user not found")
        render json: { error: "USER_NOT_FOUND", message: I18n.t("auth.errors.user_not_found") }, status: :unauthorized
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
        render json: { error: "INVALID_TOKEN", message: I18n.t("auth.errors.invalid_token") }, status: :unauthorized
      end

      private

      # BUG-027: resolve + validate the OAuth redirect_uri for this client.
      # A client-supplied redirect_uri (e.g. the extension's chromiumapp.org URL)
      # must be in Auth::RedirectUriAllowlist; absent → the provider web-callback
      # default. Returns the validated URI, or renders 400 and returns nil so the
      # caller can guard (`return unless redirect_uri`).
      def validated_redirect_uri(default)
        uri = params[:redirect_uri].presence || default
        return uri if Auth::RedirectUriAllowlist.allowed?(uri)

        Rails.logger.warn("Rejected OAuth redirect_uri: #{uri.inspect}")
        render json: {
          error: "INVALID_REDIRECT_URI",
          message: I18n.t("auth.errors.invalid_redirect_uri")
        }, status: :bad_request
        nil
      end
    end
  end
end
