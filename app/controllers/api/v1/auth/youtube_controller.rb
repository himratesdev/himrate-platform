# frozen_string_literal: true

module Api
  module V1
    module Auth
      # YouTube connect-flow (SA-2 demographics). Incremental OAuth for an ALREADY logged-in streamer to
      # grant YouTube Analytics read access. Browser flow (302s), not JSON. `connect` binds a server-side
      # state to the current user; `callback` validates that state (never trusts the browser for identity),
      # exchanges the code, and stores a "youtube" AuthProvider. Reuses the Google OAuth client + scope
      # yt-analytics.readonly; the callback host = the google callback host (derived, no new env).
      class YoutubeController < Api::BaseController
        skip_after_action :verify_authorized, raise: false
        before_action :authenticate_user_optional!, only: :connect

        STATE_TTL = 10.minutes
        DEFAULT_RETURN = "/app/settings"

        # GET /api/v1/auth/youtube/connect?return=/app/social — start the grant (must be logged in).
        def connect
          return redirect_to("/login", allow_other_host: false) unless current_user

          state = SecureRandom.hex(32)
          Rails.cache.write(state_key(state),
                            { user_id: current_user.id, return_to: safe_return(params[:return]) },
                            expires_in: STATE_TTL)
          redirect_to ::Auth::YoutubeOauth.new.authorize_url(state: state), allow_other_host: true
        end

        # GET /api/v1/auth/youtube/callback?code=&state= — Google redirects here after consent.
        def callback
          cached = Rails.cache.read(state_key(params[:state].to_s))
          return redirect_to("#{DEFAULT_RETURN}?youtube=error") if cached.nil?

          Rails.cache.delete(state_key(params[:state].to_s)) # single-use state
          @return_to = cached[:return_to]
          return redirect_to("#{@return_to}?youtube=error") if params[:code].blank?

          user = User.active.find_by(id: cached[:user_id])
          return redirect_to("#{@return_to}?youtube=error") unless user

          ::Auth::YoutubeOauth.new.connect!(code: params[:code], user: user)
          redirect_to "#{@return_to}?youtube=connected"
        rescue ActiveRecord::RecordNotUnique
          # the YouTube channel is already connected to a different HimRate account
          redirect_to "#{@return_to}?youtube=already_linked"
        rescue ::Auth::AuthError => e
          Rails.logger.warn("YoutubeController#callback: #{e.class}: #{e.message}")
          redirect_to "#{@return_to}?youtube=error"
        end

        private

        def state_key(state)
          "yt_connect:#{state}"
        end

        # only a plain same-origin /app/ path is a valid return target — rejects `//evil`, `/app/../admin`,
        # and any control char (belt-and-suspenders over Rack's own header validation).
        SAFE_RETURN = %r{\A/app/[\w\-/]*\z}

        def safe_return(value)
          v = value.to_s
          SAFE_RETURN.match?(v) ? v : DEFAULT_RETURN
        end
      end
    end
  end
end
