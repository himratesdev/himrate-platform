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

  SUNSET_HEADER = "Wed, 11 Jun 2026 00:00:00 GMT"
  DEPRECATED_AT = "2026-05-14"
  SUNSET_AT = "2026-06-11"

  private

  def render_410_gone_for_task201(endpoint:)
    log_task201_hit(endpoint)
    push_task201_metric(endpoint)
    response.headers["Sunset"] = SUNSET_HEADER
    response.headers["Deprecation"] = "true"
    render json: {
      error: "endpoint_removed",
      message: "This endpoint is removed in HimRate philosophy v2. See https://himrate.com/changelog/task-201",
      deprecated_at: DEPRECATED_AT,
      sunset_at: SUNSET_AT
    }, status: :gone
  end

  def log_task201_hit(endpoint)
    Rails.logger.info(
      msg: "TASK-201 deprecated endpoint hit",
      task: "TASK-201",
      endpoint: endpoint.to_s,
      response_code: 410,
      user_id: respond_to?(:current_user, true) ? current_user&.id : nil
    )
  end

  def push_task201_metric(endpoint)
    PrometheusMetrics.observe_task201_endpoint_hit(endpoint: endpoint.to_s)
  rescue StandardError => e
    Rails.logger.warn("Task201DeprecationResponse: prometheus push failed — #{e.class}: #{e.message}")
  end
end
