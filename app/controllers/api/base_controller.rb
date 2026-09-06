# frozen_string_literal: true

module Api
  class BaseController < ActionController::API
    include Pundit::Authorization
    # ActionController::API omits the cookie jar. The dashboard web-login (screen 70) stores the
    # access JWT in an httpOnly `hr_session` cookie so same-origin page requests authenticate
    # without exposing the token to JS. Additive: the Bearer header path is unchanged (extension
    # unaffected); cookies are only read as a fallback.
    include ActionController::Cookies

    before_action :set_locale
    after_action :verify_authorized, if: :pundit_enabled?
    after_action :log_authorized

    rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

    private

    def set_locale
      # Shared with MaintenanceMode middleware (CR A3): ?lang= query param wins,
      # then Accept-Language header, else I18n.default_locale.
      I18n.locale = LocaleResolver.call(request.env)
    end

    def authenticate_user!
      token = bearer_or_cookie_token
      unless token
        Rails.logger.warn("Auth failed: no token from #{request.remote_ip}")
        render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.bearer_required") }, status: :unauthorized
        return
      end

      payload = Auth::JwtService.decode(token)
      @surface = payload[:aud].presence || Auth::AuthContext::EXTENSION

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
      render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.auth_failed") }, status: :unauthorized
    rescue ActiveRecord::RecordNotFound
      Rails.logger.warn("Auth failed: user not found from #{request.remote_ip}")
      render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.user_not_found") }, status: :unauthorized
    end

    def authenticate_user_optional!
      token = bearer_or_cookie_token
      return unless token

      payload = Auth::JwtService.decode(token)
      @surface = payload[:aud].presence || Auth::AuthContext::EXTENSION
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

    # Bearer header first (extension / API clients — unchanged), then the httpOnly dashboard
    # session cookie (web login). Same JWT either way, so downstream decode/aud logic is identical.
    def bearer_or_cookie_token
      request.headers["Authorization"]&.split(" ")&.last.presence || web_session_token
    end

    # Web sessions: the access cookie lives 1h, the refresh cookie 7d. Without rotation the ЛК
    # hard-logged the user out after an hour (hr_refresh was written but never read) — every page
    # became "guest" and the account control showed the login screen. When hr_session is absent or
    # no longer decodes, transparently mint a fresh pair off hr_refresh (mirrors POST /auth/refresh:
    # stateless, surface preserved, refresh rotated) so the session slides up to 7 idle days.
    def web_session_token
      token = cookies.encrypted[:hr_session].presence
      if token
        begin
          Auth::JwtService.decode(token)
          return token
        rescue Auth::AuthError
          nil # expired/invalid access cookie — fall through to refresh rotation
        end
      end
      refresh_web_session
    end

    def refresh_web_session
      refresh = cookies.encrypted[:hr_refresh].presence
      return nil unless refresh

      payload = Auth::JwtService.decode(refresh)
      return nil unless payload[:type] == "refresh"

      surface = payload[:aud].presence || Auth::JwtService::DEFAULT_SURFACE
      access = Auth::JwtService.encode_access(payload[:sub], surface: surface)
      set_web_session_cookies(access, Auth::JwtService.encode_refresh(payload[:sub], surface: surface))
      access
    rescue Auth::AuthError
      nil
    end

    # httpOnly + SameSite=Lax cookies for the dashboard web session. Secure in production (staging
    # runs the production env over HTTPS); relaxed in dev/test so specs/local can read them.
    # Lives here (not AuthController) because refresh_web_session rotates the pair on any API call.
    def set_web_session_cookies(access_token, refresh_token)
      secure = Rails.env.production?
      domain = session_cookie_domain
      cookies.encrypted[:hr_session] = {
        value: access_token, httponly: true, secure: secure, same_site: :lax, expires: 1.hour, domain: domain
      }
      cookies.encrypted[:hr_refresh] = {
        value: refresh_token, httponly: true, secure: secure, same_site: :lax, expires: 7.days, domain: domain
      }
    end

    # Share the session across the himrate.com subdomains (apex ↔ app.himrate.com ↔ staging) so a web
    # login on any of them authenticates all of them. Returns nil (host-only cookie) off himrate.com
    # (localhost/dev) — a ".himrate.com" domain cookie would be rejected there. Must match the domain
    # used to CLEAR the cookie on logout (Web::AuthController#logout).
    def session_cookie_domain
      request.host.to_s.end_with?("himrate.com") ? ".himrate.com" : nil
    end

    # T1-060 FR-5: surface the request arrived on (default extension for missing/legacy aud).
    def current_surface
      @surface || Auth::AuthContext::EXTENSION
    end

    # Pundit context: policies receive (user + surface) so a tier-paywall denial resolves to
    # SUBSCRIPTION_REQUIRED on the dashboard surface vs an honest-empty data-state on the
    # extension. ApplicationPolicy#initialize unwraps this; bare-User .new calls still work.
    def pundit_user
      Auth::AuthContext.new(current_user, current_surface)
    end

    # TASK-032 FR-007: Guest identification via Extension install ID.
    # Used for: rate limiting per install_id, analytics, merge on registration.
    def extension_install_id
      @extension_install_id ||= request.headers["X-Extension-Install-Id"]
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

    # T1-060 FR-6: surface-aware paywall code. A tier-paywall denial is the hard
    # SUBSCRIPTION_REQUIRED only on the dashboard (ЛК) surface; on the extension it becomes an
    # honest-empty data-state the frontend renders WITHOUT a subscribe-wall (access-model v2 —
    # the extension is 100% free to the viewer). Forging aud=dashboard only adds locks (fail-safe).
    def paywall_code
      current_surface == Auth::AuthContext::DASHBOARD ? "SUBSCRIPTION_REQUIRED" : "EXTENSION_DEEP_LOCKED"
    end

    def resolve_error_code(exception)
      # Guests (E1) are out of the extension-no-paywall invariant (SRS §4.7 item-1, AC-4 scopes
      # to authenticated): a guest needs to register/subscribe, not "open dashboard", so keep the
      # hard SUBSCRIPTION_REQUIRED on both surfaces — never EXTENSION_DEEP_LOCKED.
      return "SUBSCRIPTION_REQUIRED" if current_user.nil?

      query = exception.query.to_s
      case exception.policy.class.name
      when "BotChainPolicy" then "BOT_CHAIN_UNAVAILABLE"
      when "StreamPolicy" then "POST_STREAM_WINDOW_EXPIRED"
      when "TrustSnapshotPolicy"
        query == "drill_down?" ? "POST_STREAM_WINDOW_EXPIRED" : paywall_code
      when "ChannelPolicy" then resolve_channel_policy_code(query)
      else paywall_code
      end
    end

    # badge? is an ownership denial (non-owner), NOT a tier paywall — it keeps a dedicated 403 code
    # on BOTH surfaces and never collapses to an honest-empty data-state. (T1-061: card? is now the
    # always-allow universal card-object — it no longer denies, so it's not handled here.)
    def resolve_channel_policy_code(query)
      case query
      when "destroy?" then "CHANNEL_NOT_TRACKED"
      when "view_report?" then "POST_STREAM_WINDOW_EXPIRED"
      when "view_365d_trends?" then "TRENDS_BUSINESS_REQUIRED"
      when "badge?" then "CHANNEL_NOT_OWNED"
      else paywall_code
      end
    end

    def resolve_cta(code)
      case code
      when "COMPARE_UNAVAILABLE", "BOT_CHAIN_UNAVAILABLE", "TRENDS_BUSINESS_REQUIRED"
        { action: "upgrade", label: I18n.t("pundit.cta.business_upgrade") }
      when "EXTENSION_DEEP_LOCKED"
        # Honest-empty on the extension: point to the dashboard, not a subscribe-wall.
        { action: "open_dashboard", label: I18n.t("pundit.cta.open_dashboard") }
      when "CHANNEL_NOT_OWNED"
        { action: "none", label: nil }
      else
        { action: "subscribe", label: I18n.t("pundit.cta.start_tracking") }
      end
    end
  end
end
