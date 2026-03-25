# frozen_string_literal: true

module Api
  module V1
    class TrustController < Api::BaseController
      before_action :authenticate_user!

      def show
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "GET /api/v1/channels/#{params[:channel_id]}/trust" } }
      end
    end
  end
end
