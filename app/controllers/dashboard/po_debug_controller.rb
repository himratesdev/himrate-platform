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

    # Gate order matters:
    #   1. Flipper disabled  → 503 (no auth challenge, surface visibly disabled)
    #   2. ENV not configured → 503
    #   3. Basic Auth check   → 401 if missing/wrong
    # This sequencing avoids leaking "is the dashboard live?" via 401 before 503.
    before_action :ensure_flag_enabled, only: :show
    before_action :ensure_password_configured, only: :show
    before_action :require_basic_auth!, only: :show

    def show
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

    def ensure_flag_enabled
      return if Flipper.enabled?(PoDebug::FLIPPER_FLAG)

      respond_to do |format|
        format.html { render plain: "po_debug_dashboard flag disabled", status: :service_unavailable }
        format.json do
          render json: { error: "po_debug_dashboard flag disabled", stale: true },
                 status: :service_unavailable
        end
      end
    end

    def ensure_password_configured
      return if ENV["PO_DEBUG_PASSWORD"].to_s.present?

      respond_to do |format|
        format.html { render plain: "PO_DEBUG_PASSWORD not configured", status: :service_unavailable }
        format.json do
          render json: { error: "PO_DEBUG_PASSWORD not configured", stale: true },
                 status: :service_unavailable
        end
      end
    end

    def require_basic_auth!
      authenticate_or_request_with_http_basic("PO Debug") do |user, pass|
        expected_user = ENV.fetch("PO_DEBUG_USER", "po")
        expected_pass = ENV["PO_DEBUG_PASSWORD"].to_s
        ActiveSupport::SecurityUtils.secure_compare(user.to_s, expected_user) &
          ActiveSupport::SecurityUtils.secure_compare(pass.to_s, expected_pass)
      end
    end
  end
end
