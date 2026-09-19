# frozen_string_literal: true

module Api
  module V1
    # Free-text channel search (by nickname OR linked social handle). Open to guests, no paywall —
    # finding a channel is navigation, not a paid analytic, and the home page's search box is the
    # first thing a visitor touches. Every surface that shows a search box (brand streamer search,
    # blogger search, watchlists "add channel", the home page) talks to this one endpoint.
    # Anonymous traffic has its own per-IP budget in config/initializers/rack_attack.rb
    # ("public_discovery/ip") — the LIKE scan is not free.
    class SearchController < Api::BaseController
      before_action :authenticate_user_optional!

      # GET /api/v1/search?q=hellgirl
      def index
        authorize :search, :search?

        results = ::Search::ChannelLookup.new(params[:q], limit: params[:limit] || 20).call
        render json: { data: results.map { |r| serialize(r) }, query: params[:q].to_s.strip }
      end

      private

      def serialize(result)
        channel = result.channel
        {
          login: channel.login,
          display_name: channel.display_name,
          avatar_url: channel.profile_image_url,
          followers: channel.followers_total,
          # Says WHY this row matched — "twitch" for the nickname, otherwise the platform whose
          # handle matched ("telegram", "youtube", …). The UI shows it as a small caption.
          matched_on: result.matched_on,
          matched_value: result.matched_value
        }
      end
    end
  end
end
