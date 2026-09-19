# frozen_string_literal: true

module Api
  module V1
    # LK-BACKEND screen 04 «Куда пойти» + the home page's live board: live-now channels ranked by real
    # audience. Open to guests (a board of public headline verdicts); a signed-in user additionally
    # gets is_watched_by_user. Compute-on-read over live streams + latest TIH. Anonymous traffic has
    # its own per-IP budget in config/initializers/rack_attack.rb ("public_discovery/ip").
    class DiscoverController < Api::BaseController
      # Filter semantics live in Discover::LiveNowQuery (single source of what is accepted).
      FILTER_PARAMS = %i[game language band min_viewers max_viewers].freeze

      before_action :authenticate_user_optional!

      # GET /api/v1/discover/live?limit=24[&game=Dota 2][&language=ru][&band=red,yellow]
      #                          [&min_viewers=100][&max_viewers=5000]
      def live
        authorize :discover, :live?
        query = ::Discover::LiveNowQuery.new(user: current_user, limit: (params[:limit] || 24).to_i,
                                             filters: params.slice(*FILTER_PARAMS))
        render json: { data: query.call }
      end
    end
  end
end
