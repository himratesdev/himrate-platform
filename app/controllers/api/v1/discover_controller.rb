# frozen_string_literal: true

module Api
  module V1
    # LK-BACKEND screen 04 «Куда пойти»: live-now channels ranked by real audience. Viewer-free
    # (any signed-in user, access-model v2) — compute-on-read over live streams + latest TIH.
    class DiscoverController < Api::BaseController
      before_action :authenticate_user!

      # GET /api/v1/discover/live?limit=24
      def live
        authorize current_user, :live?, policy_class: DiscoverPolicy
        render json: { data: ::Discover::LiveNowQuery.new(user: current_user, limit: (params[:limit] || 24).to_i).call }
      end
    end
  end
end
