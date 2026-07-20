# frozen_string_literal: true

module Api
  module V1
    module Discover
      # Screen 13 «Рост»: game opportunities per the PO spec (Steam novelty + few streamers +
      # distributed viewers). Served from the worker-warmed cache (Helix/Steam are Sidekiq-only);
      # a cold miss enqueues one refresh and reports pending. Streamer-free (any registered user).
      class GamesController < Api::BaseController
        before_action :authenticate_user!

        # GET /api/v1/discover/games
        def index
          authorize current_user, :live?, policy_class: DiscoverPolicy

          cached = Rails.cache.read(::Grow::OpportunitiesRefreshWorker::CACHE_KEY)
          if cached.nil?
            unless Rails.cache.exist?(::Grow::OpportunitiesRefreshWorker::PENDING_KEY)
              Rails.cache.write(::Grow::OpportunitiesRefreshWorker::PENDING_KEY, true,
                                expires_in: ::Grow::OpportunitiesRefreshWorker::PENDING_TTL)
              ::Grow::OpportunitiesRefreshWorker.perform_async
            end
            return render json: { data: { status: "pending", games: [] } }
          end

          render json: { data: { status: "ready", generated_at: cached["generated_at"], games: cached["games"] } }
        end
      end
    end
  end
end
