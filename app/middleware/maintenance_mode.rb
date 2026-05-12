# frozen_string_literal: true

# TASK-090 OQ-4 / SRS v1.2+ FR-019 (OQ-6 ratification): MAINTENANCE_MODE
# infrastructure for graceful deploy/downtime.
#
# Rack middleware that intercepts /api/v1/* requests when MAINTENANCE_MODE_ACTIVE=true
# and returns HTTP 503 + machine-readable JSON. Frontend can detect this state and
# render a maintenance banner instead of generic network errors.
#
# 503 / probe body contract (SRS FR-019, §10A — what the extension gates on):
#   { maintenance: true,
#     error: "MAINTENANCE_MODE",          # apiErrorCode the extension routes on
#     until: "<iso8601>", until_unix: <int>,
#     retry_after_seconds: <int>,
#     retry_after_minutes: <int>,          # Frame19 ICU-plural countdown (minutes)
#     message: "<localized>" }
# `maintenance: true` AND `error: "MAINTENANCE_MODE"` are both discriminators —
# the extension routes on `apiErrorCode` (← `error`); Frame19's countdown reads
# `retry_after_minutes` (ceil of seconds / 60). Extra fields (`maintenance`,
# `until*`, `retry_after_seconds`) are kept for PR #37 / OQ-4 compatibility.
#
# Excluded from blocking:
# - /api/v1/health/* — frontend polling endpoint(s); must stay accessible.
# - /up — Rails native health check (load balancer / Kamal proxy probe).
# Exclusions match on path boundaries (exact prefix or prefix + "/"), so a
# hypothetical /api/v1/healthcheck is NOT auto-excluded.
#
# Inserted BEFORE Rack::Attack so blocked requests don't count toward rate limits
# (see config/initializers/maintenance_mode.rb).
#
# Configuration (ENV):
#   MAINTENANCE_MODE_ACTIVE      — "true"/"false" (default false)
#   MAINTENANCE_MODE_UNTIL       — ISO 8601 datetime (optional, e.g. "2026-06-01T12:00:00Z")
#   MAINTENANCE_MODE_MESSAGE_EN  — optional EN-only message override
#   MAINTENANCE_MODE_MESSAGE_RU  — optional RU-only message override
#   MAINTENANCE_MODE_MESSAGE     — optional generic override (used for any locale
#                                  with no locale-specific override). Resolution:
#                                  locale-specific → generic → i18n api.maintenance.message.
#
# Locale: resolved by LocaleResolver (?lang= query param wins, then
# Accept-Language header, else I18n.default_locale).
class MaintenanceMode
  DEFAULT_RETRY_AFTER_SECONDS = 60
  API_PREFIX = "/api/v1"
  # Excluded if the path equals one of these or starts with "<prefix>/".
  EXCLUDED_PATH_PREFIXES = [
    "/api/v1/health"
  ].freeze
  EXCLUDED_EXACT_PATHS = [
    "/up"
  ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless active?

    request = Rack::Request.new(env)
    return @app.call(env) unless intercept?(request.path)

    log_blocked(request)
    build_response(env)
  end

  class << self
    # Returns hash describing the current maintenance status. Used both by the
    # middleware and by Api::V1::Health::MaintenanceController so the payload
    # shape stays consistent (SRS FR-019, §10A).
    #
    # `error: "MAINTENANCE_MODE"` is the apiErrorCode the extension routes on;
    # `retry_after_minutes` (ceil of seconds / 60) drives Frame19's ICU-plural
    # countdown. `until` / `until_unix` are ALWAYS non-null: when
    # MAINTENANCE_MODE_UNTIL is unset, malformed, or in the past, they are
    # derived from retry_after_seconds (now + retry_after_seconds) so the client
    # always has a sensible retry target (CR A1).
    def status_payload(locale: I18n.default_locale)
      target, seconds = retry_window
      {
        maintenance: active?,
        error: "MAINTENANCE_MODE",
        until: target.iso8601,
        until_unix: target.to_i,
        retry_after_seconds: seconds,
        retry_after_minutes: (seconds / 60.0).ceil,
        message: message_for(locale)
      }
    end

    def active?
      ActiveModel::Type::Boolean.new.cast(ENV["MAINTENANCE_MODE_ACTIVE"]) == true
    end

    def retry_after_seconds
      retry_window.last
    end

    # Resolution order: locale-specific ENV override
    # (MAINTENANCE_MODE_MESSAGE_<UPCASE-LOCALE>) → generic
    # MAINTENANCE_MODE_MESSAGE override → i18n api.maintenance.message.
    def message_for(locale)
      ENV["MAINTENANCE_MODE_MESSAGE_#{locale.to_s.upcase}"].presence ||
        ENV["MAINTENANCE_MODE_MESSAGE"].presence ||
        I18n.t("api.maintenance.message", locale: locale)
    end

    private

    # Resolves the maintenance window as [until_time(UTC), retry_after_seconds].
    # Uses the configured MAINTENANCE_MODE_UNTIL only when it is a real future
    # time; otherwise (unset / malformed / past) falls back to now + default so
    # both fields stay non-null and mutually consistent.
    def retry_window
      configured = configured_until_time
      seconds = configured ? (configured - Time.now.utc).to_i : 0
      return [ configured.utc, seconds ] if seconds.positive?

      [ Time.now.utc + DEFAULT_RETRY_AFTER_SECONDS, DEFAULT_RETRY_AFTER_SECONDS ]
    end

    # Parsed MAINTENANCE_MODE_UNTIL, or nil when unset/blank/malformed.
    # Malformed input is logged (operations doc warns to validate the value).
    def configured_until_time
      raw = ENV["MAINTENANCE_MODE_UNTIL"]
      return nil if raw.nil? || raw.strip.empty?

      Time.iso8601(raw)
    rescue ArgumentError
      Rails.logger.warn("MaintenanceMode: invalid MAINTENANCE_MODE_UNTIL=#{raw.inspect} (not ISO 8601)")
      nil
    end
  end

  private

  def active?
    self.class.active?
  end

  def intercept?(path)
    # Boundary match on API_PREFIX too (CR N1): "/api/v1foo" is NOT an API path.
    return false unless path == API_PREFIX || path.start_with?("#{API_PREFIX}/")
    return false if EXCLUDED_EXACT_PATHS.include?(path)
    return false if excluded_prefix?(path)

    true
  end

  # Boundary match: exact prefix or prefix followed by "/" — never a longer
  # word like /api/v1/healthcheck (CR A2).
  def excluded_prefix?(path)
    EXCLUDED_PATH_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
  end

  def build_response(env)
    locale = LocaleResolver.call(env)
    payload = self.class.status_payload(locale: locale)
    # Rack 3 requires lowercase header keys; "cache-control" (not "Cache-Control")
    # also stops the downstream response pipeline from layering its default
    # `cache-control: no-cache` on top of our `no-store`.
    headers = {
      "content-type" => "application/json; charset=utf-8",
      "retry-after" => payload[:retry_after_seconds].to_s,
      "cache-control" => "no-store"
    }
    [ 503, headers, [ JSON.generate(payload) ] ]
  end

  def log_blocked(request)
    Rails.logger.info(
      "MaintenanceMode: blocked path=#{request.path} ip=#{request.ip} " \
      "method=#{request.request_method} ua=#{request.user_agent.to_s[0, 80].inspect}"
    )
  end
end
