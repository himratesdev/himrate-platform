# frozen_string_literal: true

# XML sitemap of the indexable marketing pages. The Pencil-export nav is JS-driven
# (no crawlable <a href>), so the sitemap is the authoritative discovery channel for
# Google. LK app shells (/app/*), /login and API routes are intentionally excluded
# (noindex + robots Disallow). Public and unauthenticated. (TASK-060 SEO)
class SitemapsController < ApplicationController
  # Indexable marketing + legal paths, relative to the canonical apex host. The legal
  # pages (/privacy, /terms) are self-canonical and required for the Chrome Web Store
  # listing (privacy-policy URL); the marketing nav does not link them, so the sitemap
  # is their only discovery channel. Channel cards (/c/:login) are deferred — they need
  # a curated real-data set, not every login.
  PATHS = %w[/ /streamers /brands /viewers /methodology /privacy /terms].freeze

  def show
    @urls = PATHS.map { |path| "#{ApplicationHelper::CANONICAL_HOST}#{path}" }
    render layout: false, formats: :xml
  end

  private

  # Crawlers may be old — never 406 the sitemap on the modern-browser guard.
  def browser_guard_enabled?
    false
  end
end
