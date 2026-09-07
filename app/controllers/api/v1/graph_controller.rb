# frozen_string_literal: true

# W5 «Паутинка»: the audience-overlap graph. Registered-only for now (PO views it day one);
# the gate moves to business-tier with monetization — see GraphPolicy.
module Api
  module V1
    class GraphController < Api::BaseController
      before_action :authenticate_user!

      # GET /api/v1/graph/audience[?focus=login]
      def audience
        authorize :graph, :audience?
        payload = Graph::AudienceGraphService.call(focus: params[:focus])
        if payload[:error]
          render json: { error: { code: payload[:error] } }, status: :not_found
        else
          render json: { data: payload }
        end
      end
    end
  end
end
