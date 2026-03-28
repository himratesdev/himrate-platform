# frozen_string_literal: true

# TASK-018: Rate limiting for public endpoints.
# Prevents abuse of auth_events endpoint (spam, fake alerts, disk fill).

class Rack::Attack
  # Auth events: 30 requests per minute per IP
  throttle("auth_events/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/analytics/auth_events" && req.post?
  end

  # General API: 60 requests per minute per IP (CLAUDE.md §Security)
  throttle("api/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/")
  end

  # Return 429 with JSON body
  self.throttled_responder = lambda do |_matched, _env|
    [ 429, { "Content-Type" => "application/json" }, [ { error: "RATE_LIMIT_EXCEEDED" }.to_json ] ]
  end
end
