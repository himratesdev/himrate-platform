# frozen_string_literal: true

module Dashboard
  # GET /dashboard/po-debug — Hotwire HTML view (PO-only, HTTP Basic Auth).
  # GET /dashboard/po-debug.json — Same snapshot as JSON for T1 polling.
  #
  # Behind Flipper flag :po_debug_dashboard. When flag is OFF the dashboard
  # returns 503 (with informative message) so accidental access during
  # incident windows is a no-op rather than producing stale data.
  class PoDebugController < ApplicationController
    # Skip CSRF for JSON polling — Basic Auth provides the auth check.
    skip_before_action :verify_authenticity_token, only: :show, raise: false

    http_basic_authenticate_with(
      name: ENV.fetch("PO_DEBUG_USER", "po"),
      password: ENV["PO_DEBUG_PASSWORD"].to_s,
      only: :show
    )

    def show
      unless Flipper.enabled?(PoDebug::FLIPPER_FLAG)
        render_disabled
        return
      end

      if ENV["PO_DEBUG_PASSWORD"].to_s.empty?
        render plain: "PO_DEBUG_PASSWORD not configured", status: :service_unavailable
        return
      end

      @snapshot = PoDebug::Aggregator.call(force: force_refresh?)

      respond_to do |format|
        format.html
        format.json { render json: @snapshot }
      end
    end

    private

    def force_refresh?
      params[:force] == "1"
    end

    def render_disabled
      respond_to do |format|
        format.html do
          render plain: "po_debug_dashboard flag disabled", status: :service_unavailable
        end
        format.json do
          render json: { error: "po_debug_dashboard flag disabled", stale: true },
                 status: :service_unavailable
        end
      end
    end
  end
end
