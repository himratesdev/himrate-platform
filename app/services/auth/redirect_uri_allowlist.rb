# frozen_string_literal: true

module Auth
  # Server-side allowlist for OAuth redirect_uri values (BUG-027).
  #
  # The SaaS web flow and the browser-extension flow share the same OAuth
  # init/callback endpoints but need different redirect URIs:
  #   - web / SaaS → backend callback (ENV TWITCH_REDIRECT_URI / GOOGLE_REDIRECT_URI)
  #   - extension  → chrome.identity.getRedirectURL() = https://<ext-id>.chromiumapp.org/
  #
  # The client supplies its redirect_uri at init; we validate it here before
  # baking it into the provider authorize URL (and the matching token exchange),
  # so an untrusted redirect can never be requested. The per-provider web
  # defaults are always trusted; additional surfaces (extension ids, future
  # clients) are listed in the comma-separated OAUTH_ALLOWED_REDIRECT_URIS env —
  # add a URI there, no code change (scales to more clients without a deploy diff).
  module RedirectUriAllowlist
    module_function

    def allowed?(uri)
      uri.present? && entries.include?(uri)
    end

    def entries
      [
        ENV["TWITCH_REDIRECT_URI"],
        ENV["GOOGLE_REDIRECT_URI"],
        *ENV.fetch("OAUTH_ALLOWED_REDIRECT_URIS", "").split(",").map(&:strip)
      ].compact.reject(&:blank?).uniq
    end
  end
end
