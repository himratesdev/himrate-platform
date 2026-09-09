# frozen_string_literal: true

module Api
  module V1
    # Coordination rings (WEB-CONSOLIDATION §9). Public: this is a fact about a channel, and the
    # brief's access rule puts facts about a channel outside the paywall — the paid boundary is
    # working with SETS of channels, depth over a period, and exports.
    class CoordinationController < Api::BaseController
      before_action :authenticate_user_optional!

      # GET /api/v1/channels/:login/coordination
      def show
        authorize :coordination, :show?
        render json: { data: Coordination::Presenter.for_channel(params[:login]) }
      end

      # GET /api/v1/coordination/groups/:id[?focus=login]
      def group
        authorize :coordination, :show?
        payload = Coordination::Presenter.for_group(params[:id], focus: params[:focus])
        return render json: { error: { code: "GROUP_NOT_FOUND" } }, status: :not_found unless payload

        render json: { data: payload }
      end
    end
  end
end
