# frozen_string_literal: true

module Api
  module V1
    module Me
      # LK-BACKEND Wave 1b (screen 01 Home): the viewer's recently-opened channels + live channels
      # from their watchlists. Ownership-only, all-free. Hero channel-check reuses channels#card
      # (screen 02). subscriptions/follows source is deferred until wired (watchlists-only for now).
      class HomeController < Api::BaseController
        before_action :authenticate_user!

        # GET /api/v1/me/home/recent_channels
        def recent
          authorize current_user, :recent?, policy_class: HomePolicy
          render json: { data: render_headlines(::Me::RecentChannelsQuery.new(current_user).call) }
        end

        # POST /api/v1/me/home/recent_channels  { login: }
        def track_recent
          authorize current_user, :track_recent?, policy_class: HomePolicy
          result = ::Me::TrackRecentChannel.new(user: current_user, login: params[:login]).call
          return render json: { tracked: true } if result.ok

          render json: { error: { code: result.error } }, status: :not_found
        end

        # GET /api/v1/me/home/live_channels?source=watchlists
        def live_channels
          authorize current_user, :live_channels?, policy_class: HomePolicy
          source = params[:source].presence || "watchlists"
          unless source == "watchlists"
            return render json: { error: { code: "SOURCE_NOT_AVAILABLE" } }, status: :not_implemented
          end

          render json: { source: source, data: render_headlines(::Me::LiveChannelsQuery.new(current_user).call) }
        end

        private

        def render_headlines(channels)
          watched = current_user.tracked_channels.where(tracking_enabled: true).pluck(:channel_id).to_set
          channels.map do |channel|
            ChannelBlueprint.render_as_hash(channel, view: :headline, current_user: current_user, watched_channel_ids: watched)
          end
        end
      end
    end
  end
end
