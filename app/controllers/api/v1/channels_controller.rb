# frozen_string_literal: true

module Api
  module V1
    class ChannelsController < Api::BaseController
      before_action :authenticate_user!

      def index
        authorize Channel
        render json: { data: [], meta: { status: "not_implemented", endpoint: "GET /api/v1/channels" } }
      end

      def show
        channel = Channel.find(params[:id])
        authorize channel
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "GET /api/v1/channels/#{params[:id]}" } }
      end
    end
  end
end
