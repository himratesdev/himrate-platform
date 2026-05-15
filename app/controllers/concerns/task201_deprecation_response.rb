# frozen_string_literal: true

# TASK-201 Phase 1 (ADR-201, §4.1 + SRS v1.1 FR-023): 410 Gone wrapper for
# HS / Streamer Rating / Rehabilitation endpoints during the deprecation
# transition window (2026-05-14 → 2026-06-11).
#
# Behavior when `Flipper.enabled?(:hs_recommendations)` is OFF (default after
# Phase 1 migration):
#   • Pushes a gauge to prometheus-pushgateway (`task201_endpoint_hit_*`) so
#     Grafana shows whether deployed extension still hits the endpoint.
#   • Logs structured event for Loki (`task: "TASK-201"`).
#   • Sets `Sunset` + `Deprecation` headers (RFC 8594).
#   • Renders `410 Gone` with structured JSON body.
#
# Each controller includes this concern and calls
# `prepend_before_action :check_task201_deprecation` (full-action) or
# `:only:` for selective actions (Trends rehab). When Phase 4 housekeeping
# completes — concern + before_action filters + new
# `PrometheusMetrics.observe_task201_endpoint_hit` are removed (single
# touchpoint cleanup).
module Task201DeprecationResponse
  extend ActiveSupport::Concern

  # RFC 7231 §7.1.1.1 IMF-fixdate. day-name MUST match the date (2026-06-11 = Thursday).
  SUNSET_HEADER = "Thu, 11 Jun 2026 00:00:00 GMT"
  DEPRECATED_AT = "2026-05-14"
  SUNSET_AT = "2026-06-11"
  # Pointer for API consumers. ai-dev-team/CLAUDE.md §«Окружения»: production-домен
  # — TBD at Launch. Pre-Launch users ≈ 0 → forward-compatible. After Launch this
  # path will land on the public changelog page; until then it 404s harmlessly.
  CHANGELOG_URL = "https://himrate.com/changelog/task-201"

  private

  def render_410_gone_for_task201(endpoint:)
    # Pundit `after_action :verify_authorized` (Api::BaseController:8) would raise
    # AuthorizationNotPerformedError otherwise, since the wrapper short-circuits
    # before `authorize @channel, :…?` is called. `skip_authorization` marks the
    # action as "explicitly no auth check needed" — verify_authorized passes silently.
    skip_authorization if respond_to?(:skip_authorization, true)

    log_task201_hit(endpoint)
    push_task201_metric(endpoint)
    response.headers["Sunset"] = SUNSET_HEADER
    response.headers["Deprecation"] = "true"
    # RFC 7234 §4.2.2: 410 Gone is heuristically cacheable by default → CDN /
    # browser could pin the 410 indefinitely, defeating Flipper-based emergency
    # rollback. `no-store` guarantees no caching layer holds on to this response.
    response.headers["Cache-Control"] = "no-store"
    render json: {
      error: "endpoint_removed",
      message: "This endpoint is removed in HimRate philosophy v2. See #{CHANGELOG_URL}",
      deprecated_at: DEPRECATED_AT,
      sunset_at: SUNSET_AT
    }, status: :gone
  end

  # JSON-encoded log line so Loki / Promtail / jq parse it as structured data.
  # Rails.logger.info(hash) emits Ruby `#inspect` (e.g. `{:msg=>"…"}`) which is
  # not valid JSON — pipelines downstream want real JSON.
  def log_task201_hit(endpoint)
    Rails.logger.info(JSON.generate(
      msg: "TASK-201 deprecated endpoint hit",
      task: "TASK-201",
      endpoint: endpoint.to_s,
      response_code: 410,
      user_id: respond_to?(:current_user, true) ? current_user&.id : nil
    ))
  end

  def push_task201_metric(endpoint)
    PrometheusMetrics.observe_task201_endpoint_hit(endpoint: endpoint.to_s)
  rescue StandardError => e
    Rails.logger.warn("Task201DeprecationResponse: prometheus push failed — #{e.class}: #{e.message}")
  end
end
