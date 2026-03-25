# frozen_string_literal: true

module Api
  module V1
    class StreamsController < Api::BaseController
      before_action :authenticate_user!

      def index
        render json: { data: [], meta: { status: "not_implemented", endpoint: "GET /api/v1/channels/#{params[:channel_id]}/streams" } }
      end

      def show
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "GET /api/v1/channels/#{params[:channel_id]}/streams/#{params[:id]}" } }
      end
    end
  end
end
