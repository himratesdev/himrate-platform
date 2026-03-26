# frozen_string_literal: true

module Api
  module V1
    class SubscriptionsController < Api::BaseController
      before_action :authenticate_user!

      def index
        authorize Subscription
        render json: { data: [], meta: { status: "not_implemented", endpoint: "GET /api/v1/subscriptions" } }
      end

      def create
        authorize Subscription
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "POST /api/v1/subscriptions" } }
      end

      def destroy
        authorize Subscription
        render json: { data: nil, meta: { status: "not_implemented", endpoint: "DELETE /api/v1/subscriptions/#{params[:id]}" } }
      end
    end
  end
end
