# frozen_string_literal: true

module Api
  module V1
    module Brand
      # Screen 21: brand streamer card — independent 30-day track-record verification of a streamer
      # before a deal. Brand-gated, compute-on-read over existing engine (real data, no mocks).
      class StreamerCardsController < Api::BaseController
        before_action :authenticate_user!

        # GET /api/v1/brand/streamers/:login/card
        def show
          authorize current_user, :show?, policy_class: BrandStreamerCardPolicy
          result = ::Brand::StreamerCardService.new(login: params[:login]).call
          return render json: { data: result.payload } if result.ok

          render json: { error: { code: result.error } }, status: error_status(result.error)
        end

        private

        def error_status(code)
          code == "CHANNEL_NOT_FOUND" ? :not_found : :bad_request
        end
      end
    end
  end
end
