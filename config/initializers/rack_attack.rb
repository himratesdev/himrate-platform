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

  # W1: public B2B lead form (/brands) — same anti-spam budget as request_tracking.
  throttle("brand_leads/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/api/v1/brand/leads" && req.post?
  end

  # TASK-034 FR-025: Request tracking (anti-spam, 5 per hour)
  throttle("request_tracking/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path.match?(%r{/api/v1/channels/.+/request_tracking}) && req.post?
  end

  # TASK-113 BE-5 (CR Nit-3): PVA export — heavy async job (MAX_RECORDS_PER_TABLE × N таблиц).
  # 5/hour достаточно для real GDPR-запросов + предотвращает DOS через flood of export-jobs.
  throttle("pva_export/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/api/v1/me/analytics/export" && req.post?
  end

  # Public landing compute endpoints (no auth, not under /api/): the dynamic OG image
  # (/og/c/:login.png → server-side avatar fetch + libvips render) and the public
  # channel card (/c/:login). CDN caches them, but cache-miss / cache-buster requests
  # hit the app directly — throttle so they can't be used to hammer the box. (landing hardening)
  throttle("og_image/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/og/") && !req.options?
  end

  throttle("channel_card/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.match?(%r{\A/c/[^/]+\z}) && !req.options?
  end

  # EPIC-64: public category tops (/top, /top/:slug) — server-rendered from cached
  # aggregates (1h/6h TTL), but a cache-miss recomputes a 30-day GROUP BY; same
  # per-IP budget as the channel card.
  throttle("public_top/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.match?(%r{\A/top(/[^/]+)?\z}) && !req.options?
  end

  # WEB-CONSOLIDATION: the home page's search box and live board answer guests by code. Search is a
  # LIKE scan over channels + social links, the board a LATERAL ranking over every live channel, so
  # an ANONYMOUS visitor gets half the general per-IP budget on these two paths (same as the OG
  # renderer). Anonymous = no Authorization header and no web-session cookie: a signed-in reader
  # never matches this rule and keeps exactly today's budgets (api/ip + api/user). A forged header
  # only buys back the general api/ip budget, which applies to everyone anyway.
  PUBLIC_DISCOVERY_PATHS = %w[/api/v1/search /api/v1/discover/live].freeze

  throttle("public_discovery/ip", limit: 30, period: 1.minute) do |req|
    # Rails normalizes the path AFTER this middleware (Journey squeezes `//`, drops a trailing `/`),
    # so `/api/v1/search/` reaches the same action — match the normalized form or the budget is dodged.
    # Neither route declares `format: false`, so Journey also accepts the `(.:format)` suffix every
    # Rails route carries: `/api/v1/search.json` is the SAME action with :format => "json". Strip a
    # trailing extension too, or the budget is dodged one `.anything` at a time (CR iter-2 SF-3).
    path = req.path.squeeze("/").chomp("/").sub(/\.[^\/.]+\z/, "")
    next unless PUBLIC_DISCOVERY_PATHS.include?(path) && !req.options?

    anonymous = req.get_header("HTTP_AUTHORIZATION").blank? &&
                req.cookies["hr_session"].blank? && req.cookies["hr_refresh"].blank?
    req.ip if anonymous
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
          # BUG-251.16: single-source the signing secret + algorithm from Auth::JwtService. The old
          # ENV.fetch("JWT_SECRET", "") defaulted to a blank key (the empty-key vector this fix
          # removes) AND diverged from how tokens are actually signed — when JWT_SECRET is unset,
          # JwtService signs with secret_key_base, so decoding with "" here failed every token and
          # silently dropped the per-user limit back to IP-only. (Per-request lambda → constant is
          # loaded by call time.)
          payload = JWT.decode(token, Auth::JwtService::SECRET, true,
                               { algorithm: Auth::JwtService::ALGORITHM }).first
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
