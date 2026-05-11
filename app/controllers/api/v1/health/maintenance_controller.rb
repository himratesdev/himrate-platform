# frozen_string_literal: true

# TASK-090 OQ-4: /api/v1/health/maintenance — polling endpoint for frontend.
#
# Always returns HTTP 200 (NOT 503) — clients poll this to detect the
# beginning/end of a maintenance window. Body mirrors the middleware payload
# so the frontend has a single shape to parse.
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
