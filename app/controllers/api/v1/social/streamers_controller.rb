# frozen_string_literal: true

module Api
  module V1
    module Social
      # EPIC Social Analytics (SA-1) — a streamer's cross-platform social profile: footprint
      # auto-discovered from Twitch + DESCRIPTIVE per-platform analytics (reach/viewability/cadence/
      # growth). Public data (like the channel card), served from the worker-warmed cache; a cold miss
      # enqueues one refresh and reports pending (Grow/Moments pattern). NO fraud verdict — descriptive
      # only (PO 2026-07-21: накрутку соцсетей не оцениваем).
      class StreamersController < Api::BaseController
        skip_after_action :verify_authorized
        before_action :authenticate_user_optional!

        # GET /api/v1/social/streamers/:login
        def show
          login = params[:login].to_s.strip.downcase
          return render json: { error: "INVALID_LOGIN" }, status: :bad_request if login.blank?

          cached = Rails.cache.read(::SocialAnalytics::ProfileRefreshWorker.cache_key(login))
          if cached.nil?
            warm(login)
            return render json: { data: { status: "pending", login: login } }
          end

          render json: { data: cached.merge(status: "ready") }
        end

        private

        def warm(login)
          pending = ::SocialAnalytics::ProfileRefreshWorker.pending_key(login)
          return if Rails.cache.exist?(pending)

          Rails.cache.write(pending, true, expires_in: ::SocialAnalytics::ProfileRefreshWorker::PENDING_TTL)
          ::SocialAnalytics::ProfileRefreshWorker.perform_async(login)
        end
      end
    end
  end
end
