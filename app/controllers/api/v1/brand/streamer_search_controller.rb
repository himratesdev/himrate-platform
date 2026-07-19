# frozen_string_literal: true

module Api
  module V1
    module Brand
      # Screen 20: brand streamer search/discovery — ranked by real 30-day audience with filters.
      # Brand-gated, compute-on-read over trends_daily_aggregates (real data, no mocks).
      class StreamerSearchController < Api::BaseController
        before_action :authenticate_user!

        # GET /api/v1/brand/streamers/search?category=&language=&min_real=&frequency=&classification=&sort=&page=&per_page=
        def index
          authorize current_user, :index?, policy_class: BrandStreamerSearchPolicy
          render json: ::Brand::StreamerSearchQuery.new(search_params).call
        end

        private

        def search_params
          params.permit(:category, :language, :min_real, :frequency, :classification, :sort, :page, :per_page)
        end
      end
    end
  end
end
