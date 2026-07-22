# frozen_string_literal: true

module Web
  # Dashboard web login (screen 70). Starts the Twitch OAuth flow for a BROWSER (302 to Twitch),
  # reusing Auth::TwitchOauth + the already-registered /api/v1/auth/twitch/callback (which sets the
  # httpOnly session cookie on the `web:true` branch), so no new Twitch redirect URI is needed. This
  # controller is isolated from the extension's /api/v1/auth/* API flow.
  class AuthController < ApplicationController
    # After a successful web login, land the user INSIDE the dashboard — not back on /login. Previously
    # web_redirect was "/login", so the callback bounced the user to the login page in a "logged-in"
    # limbo (login.js showed «Вы вошли» + a repurposed Twitch-icon logout button) instead of entering
    # the LK. /app/home (viewer home) is the default landing; role-specific sections open from the nav.
    DASHBOARD_HOME = "/app/home"

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
        { code_verifier: result[:code_verifier], redirect_uri: redirect_uri, web: true, web_redirect: DASHBOARD_HOME },
        expires_in: 10.minutes
      )
      redirect_to result[:redirect_url], allow_other_host: true
    end

    # GET /auth/web/google — begin browser OAuth via Google, mirroring #twitch: reuses
    # Auth::GoogleOauth + the registered /api/v1/auth/google/callback (its web:true branch sets the
    # httpOnly session cookie), so no new Google redirect URI is needed.
    def google
      redirect_uri = ENV.fetch("GOOGLE_REDIRECT_URI")
      result = Auth::GoogleOauth.new.authorize_url(redirect_uri: redirect_uri)

      Rails.cache.write(
        "google_state:#{result[:state]}",
        { redirect_uri: redirect_uri, web: true, web_redirect: DASHBOARD_HOME },
        expires_in: 10.minutes
      )
      redirect_to result[:redirect_url], allow_other_host: true
    end

    # DELETE /auth/web/logout — clear the session cookies. Called via fetch(DELETE) from login.js
    # (state-changing, so DELETE not GET → no logout-CSRF via top-level navigation). 204; the client
    # reloads /login to show the logged-out state.
    def logout
      # Clear BOTH the host-only cookie (legacy, pre-subdomain) AND the ".himrate.com" cookie the login
      # now sets (Api::V1::AuthController#session_cookie_domain), so logout works across the transition
      # and across subdomains. A cookie is only cleared by delete() when the domain matches how it was set.
      domain = request.host.to_s.end_with?("himrate.com") ? ".himrate.com" : nil
      %i[hr_session hr_refresh].each do |name|
        cookies.delete(name)
        cookies.delete(name, domain: domain) if domain
      end
      head :no_content
    end
  end
end
