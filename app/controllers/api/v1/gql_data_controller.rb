# frozen_string_literal: true

# TASK-022 FR-021: Backend endpoint for receiving Extension-side GQL data
# Extension makes integrity-protected GQL calls from browser context
# and sends results here for server-side processing.

module Api
  module V1
    class GqlDataController < BaseController
      skip_after_action :verify_authorized # Auth via JWT, no Pundit policy needed
      before_action :authenticate_user!

      VALID_DATA_TYPES = %w[chatters_count community_tab social_medias user_follows].freeze

      def create
        channel = Channel.find_by!(twitch_id: params[:channel_id])

        unless VALID_DATA_TYPES.include?(data_params[:data_type])
          return render json: { error: "INVALID_DATA_TYPE", valid: VALID_DATA_TYPES }, status: :unprocessable_entity
        end

        Rails.logger.info(
          "GQL data received: type=#{data_params[:data_type]} channel=#{channel.twitch_id} user=#{current_user.id}"
        )

        render json: { status: "accepted", data_type: data_params[:data_type] }, status: :created
      end

      private

      def data_params
        permitted = params.permit(:data_type, :channel_id)
        permitted[:payload] = params[:payload].permit! if params[:payload].present?
        permitted
      end
    end
  end
end
