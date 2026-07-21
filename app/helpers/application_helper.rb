# frozen_string_literal: true

module ApplicationHelper
  # Canonical public host for the marketing site. The apex (no `www`) is the only
  # variant with a valid origin certificate and a 200 response; `www.himrate.com`
  # is redirected to it at the CDN. Every landing page emits a self-referencing
  # canonical to this host so Google consolidates on the apex even when it crawls
  # the site via `www`, `http`, or `staging.` (TASK-060 SEO canonicalisation).
  CANONICAL_HOST = "https://himrate.com"
  CANONICAL_HOST_NAME = "himrate.com"

  # Single source of truth for "this request is serving the public production site".
  # Gated on the canonical hostname, NOT Rails.env: the public apex follows the
  # `himrate.com` hostname regardless of which box serves it, so this stays correct
  # through the eventual clean-prod cutover (prod takes over the hostname → still true;
  # staging.himrate.com / localhost → false). Everything that must fire only on the
  # real public site (analytics, indexing hints) keys off this.
  def public_site?
    request.host == CANONICAL_HOST_NAME
  end

  # Self-referencing canonical URL for the current request: apex host + path, with
  # the query string dropped (canonical URLs must not carry per-request params).
  def canonical_url
    "#{CANONICAL_HOST}#{request.path}"
  end

  # Absolute asset URL on the canonical host — for og:image / icons that must be
  # absolute and host-stable regardless of which hostname served the page.
  def canonical_asset_url(logical_path)
    "#{CANONICAL_HOST}#{asset_path(logical_path)}"
  end

  # Analytics (Metrika + GA4) load ONLY on the public production site so staging and
  # localhost never pollute the stats. (TASK-060)
  def analytics_enabled?
    public_site?
  end
end
