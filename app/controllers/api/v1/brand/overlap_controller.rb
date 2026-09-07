# frozen_string_literal: true

module Api
  module V1
    module Brand
      # Screen 24: audience overlap between 2-4 channels, brand-gated, compute-on-read from the
      # chat-presence graph (cross_channel_presences). Chatters-only basis (audience_basis).
      class OverlapController < Api::BaseController
        before_action :authenticate_user!

        # GET /api/v1/brand/overlap?channels=a,b,c
        def index
          authorize current_user, :index?, policy_class: BrandOverlapPolicy
          result = ::Brand::AudienceOverlapService.new(channel_logins).call
          return render json: result.payload if result.ok

          render json: { error: { code: result.error } }, status: error_status(result.error)
        end

        private

        def channel_logins
          params[:channels].to_s.split(",")
        end

        def error_status(code)
          code == "CHANNEL_NOT_FOUND" ? :not_found : :bad_request
        end
      end
    end
  end
end
