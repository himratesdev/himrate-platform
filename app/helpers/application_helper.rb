# frozen_string_literal: true

module ApplicationHelper
  # Canonical public host for the marketing site. The apex (no `www`) is the only
  # variant with a valid origin certificate and a 200 response; `www.himrate.com`
  # is redirected to it at the CDN. Every landing page emits a self-referencing
  # canonical to this host so Google consolidates on the apex even when it crawls
  # the site via `www`, `http`, or `staging.` (TASK-060 SEO canonicalisation).
  CANONICAL_HOST = "https://himrate.com"

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

  # Analytics (Metrika + GA4) load ONLY on the canonical production host so staging
  # and localhost never pollute the stats. (TASK-060)
  def analytics_enabled?
    request.host == URI(CANONICAL_HOST).host
  end
end
