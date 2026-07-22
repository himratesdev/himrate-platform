# frozen_string_literal: true

module Api
  module V1
    module Social
      # EPIC Social Analytics (value-roadmap C2) — the descriptive Twitch → socials funnel: overlays a
      # streamer's Twitch broadcast timeline on their social activity/growth and surfaces temporal
      # co-occurrences (a social spike that follows a stream). Reads the SAME worker-warmed social
      # profile as the streamers endpoint (a cold miss enqueues one refresh and reports pending —
      # Grow/Moments pattern), then correlates it against streams/snapshots from PG. HONEST framing:
      # temporal correlation, NOT causation. NO fraud verdict (PO 2026-07-21: накрутку не оцениваем).
      class AttributionController < Api::BaseController
        include SocialProfileWarming

        skip_after_action :verify_authorized
        before_action :authenticate_user_optional!

        # GET /api/v1/social/streamers/:login/attribution
        def show
          login = params[:login].to_s.strip.downcase
          return render json: { error: "INVALID_LOGIN" }, status: :bad_request if login.blank?

          cached = Rails.cache.read(::SocialAnalytics::ProfileRefreshWorker.cache_key(login))
          if cached.nil?
            warm_social_profile(login)
            return render json: { data: { status: "pending", login: login } }
          end

          funnel = ::SocialAnalytics::Attribution::StreamerFunnel.call(login, profile: cached)
          render json: { data: funnel.merge(status: "ready") }
        end
      end
    end
  end
end
