# frozen_string_literal: true

module Api
  module V1
    module Brand
      # Screen 23: compare 2-4 streamers by real 30-day audience (+ optional brand-supplied price →
      # price per real viewer). Brand-gated, compute-on-read over existing engine (real data, no mocks).
      class CompareController < Api::BaseController
        before_action :authenticate_user!

        # GET /api/v1/brand/compare?channels=a,b,c&prices=180000,120000,240000
        def index
          authorize current_user, :index?, policy_class: BrandComparePolicy
          result = ::Brand::CompareService.new(logins: channel_logins, prices: price_list).call
          return render json: result.payload if result.ok

          render json: { error: { code: result.error } }, status: error_status(result.error)
        end

        private

        def channel_logins
          params[:channels].to_s.split(",")
        end

        def price_list
          params[:prices].to_s.split(",")
        end

        def error_status(code)
          code == "CHANNEL_NOT_FOUND" ? :not_found : :bad_request
        end
      end
    end
  end
end
