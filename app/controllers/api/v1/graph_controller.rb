# frozen_string_literal: true

# W5 «Паутинка»: the audience-overlap graph. Public since 2026-09-09 — the neighbours block on
# the channel card reads this same ego payload, and who a channel shares its audience with is a
# fact about that channel. See GraphPolicy for the access rationale.
module Api
  module V1
    class GraphController < Api::BaseController
      before_action :authenticate_user_optional!

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
