# frozen_string_literal: true

# TASK-031 FR-001/009: User profile API.

module Api
  module V1
    class UsersController < Api::BaseController
      before_action :authenticate_user!
      skip_after_action :verify_authorized

      # FR-001: GET /api/v1/user/me
      def me
        render json: { data: UserBlueprint.render_as_hash(current_user) }
      end

      # FR-009: PATCH /api/v1/user/me
      def update
        if current_user.update(user_params)
          render json: { data: UserBlueprint.render_as_hash(current_user) }
        else
          render json: { error: "VALIDATION_ERROR", details: current_user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def user_params
        params.permit(:username, :goal_tag)
      end
    end
  end
end
