# frozen_string_literal: true

module Api
  module V1
    module Me
      # ONBOARD-D0 (screen 11 «Подключение»): the streamer's own-channel data-source status.
      # Ownership-free (always the CURRENT user's twitch identity), all values REAL:
      # observation state, OAuth link + scopes, and live collection stats.
      class ConnectController < Api::BaseController
        before_action :authenticate_user!

        # GET /api/v1/me/connect/status
        def status
          authorize current_user, :status?, policy_class: ConnectPolicy
          render json: { data: ::Me::ConnectStatusQuery.new(current_user).call }
        end
      end
    end
  end
end
