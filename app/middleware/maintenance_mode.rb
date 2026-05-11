# frozen_string_literal: true

# TASK-090 OQ-4: MAINTENANCE_MODE infrastructure for graceful deploy/downtime.
#
# Rack middleware that intercepts /api/v1/* requests when MAINTENANCE_MODE_ACTIVE=true
# and returns HTTP 503 + machine-readable JSON. Frontend can detect this state and
# render a maintenance banner instead of generic network errors.
#
# Excluded from blocking:
# - /api/v1/health/* — frontend polling endpoint(s); must stay accessible.
# - /up — Rails native health check (load balancer / Kamal proxy probe).
#
# Inserted BEFORE Rack::Attack so blocked requests don't count toward rate limits
# (see config/initializers/maintenance_mode.rb).
#
# Configuration (ENV):
#   MAINTENANCE_MODE_ACTIVE   — "true"/"false" (default false)
#   MAINTENANCE_MODE_UNTIL    — ISO 8601 datetime (optional, e.g. "2026-05-12T20:30:00Z")
#   MAINTENANCE_MODE_MESSAGE  — optional override; default uses i18n keys
#                               api.maintenance.message (en/ru).
#
# Locale: detected from `Accept-Language` header or `?lang=` query param.
# Default locale = I18n.default_locale (currently :en).
class MaintenanceMode
  DEFAULT_RETRY_AFTER_SECONDS = 60
  API_PREFIX = "/api/v1"
  # Exclusions are matched as prefix (excluded if path starts with one of these).
  EXCLUDED_PATH_PREFIXES = [
    "/api/v1/health"
  ].freeze
  EXCLUDED_EXACT_PATHS = [
    "/up"
  ].freeze
  AVAILABLE_LOCALES = %i[en ru].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless active?

    request = Rack::Request.new(env)
    return @app.call(env) unless intercept?(request.path)

    log_blocked(request)
    build_response(request)
  end

  class << self
    # Returns hash describing the current maintenance status. Used both by the
    # middleware and by Api::V1::Health::MaintenanceController so the payload
    # shape stays consistent.
    def status_payload(locale: I18n.default_locale)
      {
        maintenance: active?,
        until: until_iso8601,
        until_unix: until_unix,
        message: message_for(locale),
        retry_after_seconds: retry_after_seconds
      }
    end

    def active?
      ActiveModel::Type::Boolean.new.cast(ENV["MAINTENANCE_MODE_ACTIVE"]) == true
    end

    def until_time
      raw = ENV["MAINTENANCE_MODE_UNTIL"]
      return nil if raw.nil? || raw.strip.empty?

      Time.iso8601(raw)
    rescue ArgumentError
      # Invalid ISO 8601 — log and treat as "no until set" rather than crashing
      # the middleware. Operations doc warns to validate the value.
      Rails.logger.warn("MaintenanceMode: invalid MAINTENANCE_MODE_UNTIL=#{raw.inspect} (not ISO 8601)")
      nil
    end

    def until_iso8601
      until_time&.utc&.iso8601
    end

    def until_unix
      until_time&.to_i
    end

    def retry_after_seconds
      target = until_time
      return DEFAULT_RETRY_AFTER_SECONDS if target.nil?

      seconds = (target - Time.now.utc).to_i
      seconds.positive? ? seconds : DEFAULT_RETRY_AFTER_SECONDS
    end

    def message_for(locale)
      override = ENV["MAINTENANCE_MODE_MESSAGE"]
      return override if override.present?

      I18n.t("api.maintenance.message", locale: locale)
    end
  end

  private

  def active?
    self.class.active?
  end

  def intercept?(path)
    return false unless path.start_with?(API_PREFIX)
    return false if EXCLUDED_EXACT_PATHS.include?(path)
    return false if EXCLUDED_PATH_PREFIXES.any? { |prefix| path.start_with?(prefix) }

    true
  end

  def build_response(request)
    locale = detect_locale(request)
    payload = self.class.status_payload(locale: locale)
    retry_after = payload[:retry_after_seconds]

    headers = {
      "Content-Type" => "application/json; charset=utf-8",
      "Retry-After" => retry_after.to_s,
      "Cache-Control" => "no-store"
    }
    [ 503, headers, [ JSON.generate(payload) ] ]
  end

  def detect_locale(request)
    # Query param wins (explicit user choice), then Accept-Language header.
    candidates = []
    candidates << request.params["lang"] if request.params["lang"].present?
    candidates << request.get_header("HTTP_ACCEPT_LANGUAGE")
    candidates.each do |source|
      next if source.blank?

      tag = source.to_s.downcase.scan(/[a-z]{2}/).first
      sym = tag&.to_sym
      return sym if sym && AVAILABLE_LOCALES.include?(sym)
    end
    I18n.default_locale
  rescue Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError
    # Malformed query string — fall back silently.
    I18n.default_locale
  end

  def log_blocked(request)
    Rails.logger.info(
      "MaintenanceMode: blocked path=#{request.path} ip=#{request.ip} " \
      "method=#{request.request_method} ua=#{request.user_agent.to_s[0, 80].inspect}"
    )
  end
end
