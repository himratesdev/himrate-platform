# frozen_string_literal: true

module Api
  module V1
    class StreamsController < Api::BaseController
      before_action :authenticate_user!

      def index
        channel = Channel.find(params[:channel_id])
        authorize channel, policy_class: StreamPolicy
        render json: { data: [], meta: { status: "not_implemented", endpoint: "GET /api/v1/channels/#{params[:channel_id]}/streams" } }
      end

      def show
        channel = Channel.find(params[:channel_id])
        authorize channel, policy_class: StreamPolicy
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "GET /api/v1/channels/#{params[:channel_id]}/streams/#{params[:id]}" } }
      end
    end
  end
end
