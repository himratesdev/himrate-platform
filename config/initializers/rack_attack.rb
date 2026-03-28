# frozen_string_literal: true

# TASK-020: Full rate limiting + brute force protection.
# Rules ordered from most specific to general.

class Rack::Attack
  # === Safelist ===

  safelist("localhost") do |req|
    req.ip == "127.0.0.1" || req.ip == "::1"
  end

  SAFELISTED_IPS = ENV.fetch("RACK_ATTACK_SAFELIST_IPS", "").split(",").map(&:strip).freeze

  safelist("staging_ips") do |req|
    SAFELISTED_IPS.include?(req.ip)
  end

  # === Exclude OPTIONS preflight from all throttles ===

  # OPTIONS requests are CORS preflight — never count toward rate limits.
  # rack-cors (position 0) handles them before Rack::Attack, but
  # defense-in-depth: skip throttle matching for OPTIONS.

  # === Throttle rules (most specific first) ===

  # Admin panel brute force protection (HTTP Basic Auth)
  throttle("admin/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/admin/") && !req.options?
  end

  # Auth endpoints brute force (OAuth credential stuffing)
  throttle("auth/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/auth") && !req.options?
  end

  # Auth events (public endpoint, TASK-018)
  throttle("auth_events/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/analytics/auth_events" && req.post?
  end

  # General API per IP
  throttle("api/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/") && !req.options?
  end

  # Per-user API (authenticated, by JWT user_id)
  throttle("api/user", limit: 300, period: 1.minute) do |req|
    if req.path.start_with?("/api/") && !req.options?
      # Extract user_id from JWT Bearer token (lightweight, no DB hit)
      token = req.get_header("HTTP_AUTHORIZATION")&.delete_prefix("Bearer ")
      if token.present?
        begin
          payload = JWT.decode(token, ENV.fetch("JWT_SECRET", ""), true, { algorithm: "HS256" }).first
          payload["sub"]
        rescue JWT::DecodeError, JWT::VerificationError
          nil
        end
      end
    end
  end

  # === Response ===

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    period = match_data[:period] || 60
    now = Time.current.to_i
    retry_after = (period - (now % period)).to_s

    [ 429,
      { "Content-Type" => "application/json", "Retry-After" => retry_after },
      [ { error: "RATE_LIMIT_EXCEEDED", retry_after: retry_after.to_i }.to_json ] ]
  end
end
