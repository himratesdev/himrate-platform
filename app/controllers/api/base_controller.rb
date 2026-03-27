# frozen_string_literal: true

module Api
  class BaseController < ActionController::API
    include Pundit::Authorization

    around_action :set_locale
    after_action :verify_authorized, if: :pundit_enabled?
    after_action :log_authorized

    rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

    private

    def set_locale(&action)
      locale = extract_locale_from_header
      I18n.with_locale(locale, &action)
    end

    def extract_locale_from_header
      header = request.headers["Accept-Language"].to_s
      preferred = header.downcase.scan(/[a-z]{2}/).first&.to_sym
      I18n.available_locales.include?(preferred) ? preferred : I18n.default_locale
    end

    def authenticate_user!
      token = request.headers["Authorization"]&.split(" ")&.last
      unless token
        Rails.logger.warn("Auth failed: no token from #{request.remote_ip}")
        render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.bearer_required") }, status: :unauthorized
        return
      end

      payload = Auth::JwtService.decode(token)

      unless payload[:type] == "access"
        Rails.logger.warn("Auth failed: non-access token from #{request.remote_ip}")
        render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.access_required") }, status: :unauthorized
        return
      end

      @current_user = User.active
                          .includes(:subscriptions, :tracked_channels, :auth_providers)
                          .find(payload[:sub])
    rescue Auth::AuthError => e
      Rails.logger.warn("Auth failed: #{e.class} from #{request.remote_ip}")
      render json: { error: "UNAUTHORIZED", message: e.message }, status: :unauthorized
    rescue ActiveRecord::RecordNotFound
      Rails.logger.warn("Auth failed: user not found from #{request.remote_ip}")
      render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.user_not_found") }, status: :unauthorized
    end

    def authenticate_user_optional!
      token = request.headers["Authorization"]&.split(" ")&.last
      return unless token

      payload = Auth::JwtService.decode(token)
      return unless payload[:type] == "access"

      @current_user = User.active
                          .includes(:subscriptions, :tracked_channels, :auth_providers)
                          .find(payload[:sub])
    rescue Auth::AuthError, ActiveRecord::RecordNotFound
      @current_user = nil
    end

    def current_user
      @current_user
    end

    def pundit_enabled?
      Flipper.enabled?(:pundit_authorization)
    end

    def render_forbidden(exception)
      error_payload = authorization_error_payload(exception)

      Rails.logger.info(
        "Authorization denied: user=#{current_user&.id} " \
        "policy=#{exception.policy.class} action=#{exception.query} " \
        "code=#{error_payload[:error][:code]}"
      )

      render json: error_payload, status: :forbidden
    end

    def log_authorized
      Rails.logger.debug(
        "Authorization granted: user=#{current_user&.id} " \
        "controller=#{controller_name} action=#{action_name}"
      )
    end

    def authorization_error_payload(exception)
      code = resolve_error_code(exception)

      {
        error: {
          code: code,
          message: I18n.t("pundit.errors.#{code.downcase}"),
          cta: resolve_cta(code)
        }
      }
    end

    def resolve_error_code(exception)
      return "SUBSCRIPTION_REQUIRED" if current_user.nil?

      policy_name = exception.policy.class.name
      query = exception.query.to_s

      case policy_name
      when "BotChainPolicy"
        "BOT_CHAIN_UNAVAILABLE"
      when "StreamPolicy"
        "POST_STREAM_WINDOW_EXPIRED"
      when "TrustSnapshotPolicy"
        query == "drill_down?" ? "POST_STREAM_WINDOW_EXPIRED" : "SUBSCRIPTION_REQUIRED"
      when "ChannelPolicy"
        query == "destroy?" ? "CHANNEL_NOT_TRACKED" : "SUBSCRIPTION_REQUIRED"
      else
        "SUBSCRIPTION_REQUIRED"
      end
    end

    def resolve_cta(code)
      case code
      when "COMPARE_UNAVAILABLE", "BOT_CHAIN_UNAVAILABLE"
        { action: "upgrade", label: I18n.t("pundit.cta.business_upgrade") }
      else
        { action: "subscribe", label: I18n.t("pundit.cta.start_tracking") }
      end
    end
  end
end
