# frozen_string_literal: true

module Api
  module V1
    class WatchlistsController < Api::BaseController
      before_action :authenticate_user!

      def index
        authorize Watchlist
        render json: { data: [], meta: { status: "not_implemented", endpoint: "GET /api/v1/watchlists" } }
      end

      def create
        authorize Watchlist
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "POST /api/v1/watchlists" } }
      end

      def destroy
        watchlist = current_user.watchlists.find(params[:id])
        authorize watchlist
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "DELETE /api/v1/watchlists/#{params[:id]}" } }
      end
    end
  end
end
