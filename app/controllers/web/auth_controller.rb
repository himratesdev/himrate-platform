# frozen_string_literal: true

module Web
  # Dashboard web login (screen 70). Starts the Twitch OAuth flow for a BROWSER (302 to Twitch),
  # reusing Auth::TwitchOauth + the already-registered /api/v1/auth/twitch/callback (which sets the
  # httpOnly session cookie on the `web:true` branch), so no new Twitch redirect URI is needed. This
  # controller is isolated from the extension's /api/v1/auth/* API flow.
  class AuthController < ApplicationController
    # Login must reach the widest audience — skip the modern-browser guard (mirrors PagesController).
    def browser_guard_enabled?
      false
    end

    # GET /auth/web/twitch — begin browser OAuth, land back on the dashboard with a session cookie.
    def twitch
      redirect_uri = ENV.fetch("TWITCH_REDIRECT_URI")
      result = Auth::TwitchOauth.new.authorize_url(redirect_uri: redirect_uri)

      Rails.cache.write(
        "pkce:#{result[:state]}",
        { code_verifier: result[:code_verifier], redirect_uri: redirect_uri, web: true, web_redirect: "/login" },
        expires_in: 10.minutes
      )
      redirect_to result[:redirect_url], allow_other_host: true
    end

    # DELETE /auth/web/logout — clear the session cookies. Called via fetch(DELETE) from login.js
    # (state-changing, so DELETE not GET → no logout-CSRF via top-level navigation). 204; the client
    # reloads /login to show the logged-out state.
    def logout
      cookies.delete(:hr_session)
      cookies.delete(:hr_refresh)
      head :no_content
    end
  end
end
