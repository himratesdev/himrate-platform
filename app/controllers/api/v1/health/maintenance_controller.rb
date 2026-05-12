# frozen_string_literal: true

# TASK-090 OQ-4 / SRS FR-019: /api/v1/health/maintenance — polling endpoint
# for the frontend.
#
# Always returns HTTP 200 (NOT 503) — clients poll this every ~30s to detect the
# beginning/end of a maintenance window. When maintenance is ON the body mirrors
# the middleware's 503 payload exactly (incl. `error: "MAINTENANCE_MODE"` and
# `retry_after_minutes`) so the frontend has a single shape to parse; when OFF it
# returns `{ maintenance: false, status: "ok" }` (no `error` field).
#
# This controller is intentionally NOT blocked by MaintenanceMode middleware
# (path prefix `/api/v1/health` is in EXCLUDED_PATH_PREFIXES).
module Api
  module V1
    module Health
      class MaintenanceController < Api::BaseController
        # No auth: status is operational info, not user-scoped data.
        # No Pundit: this endpoint has no record/policy semantics.
        skip_after_action :verify_authorized, raise: false

        def show
          # No caching: a CDN/proxy must never serve a stale {maintenance:false}
          # to a 30s poller (parity with the 503's Cache-Control: no-store).
          response.cache_control.replace(no_store: true)

          if ::MaintenanceMode.active?
            render json: ::MaintenanceMode.status_payload(locale: I18n.locale), status: :ok
          else
            render json: { maintenance: false, status: "ok" }, status: :ok
          end
        end
      end
    end
  end
end
