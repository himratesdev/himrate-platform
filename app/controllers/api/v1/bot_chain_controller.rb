# frozen_string_literal: true

module Api
  module V1
    class BotChainController < Api::BaseController
      before_action :authenticate_user_optional!

      def show
        channel = Channel.find(params[:channel_id])
        authorize channel, policy_class: BotChainPolicy
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "GET /api/v1/channels/#{params[:channel_id]}/bot-chain" } }
      end
    end
  end
end
