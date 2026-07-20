# frozen_string_literal: true

# Public marketing landing (TASK-060). Faithful Rails host of the Pencil export:
# each action renders the export's page on a dedicated `landing` layout that pulls
# in production-built Tailwind, self-hosted fonts, and the export's own vanilla JS
# (hr-i18n.js client-side RU/EN + hr-shared.js animated background). No auth — these
# are public GET pages; API / extension traffic (api/v1/*) is unaffected.
class PagesController < ApplicationController
  layout "landing"

  PAGES = %w[index streamers brands viewers methodology login].freeze

  # One action per page; @page selects the per-page JS bundle in the layout.
  PAGES.each do |page|
    define_method(page) { @page = page }
  end

  # Public channel card (screen 02) — faithful export host. Real data is wired client-side by
  # landing/channel_card.js against the public GET /api/v1/channels/:login/card (headline +
  # reputation are free on any channel per access-model v2). No auth.
  def channel_card
    @page = "channel_card"
    @login = params[:login]
  end

  # Brand dashboard streamer search (screen 20) — faithful export host. Real ranked results are wired
  # client-side by landing/brand_search.js against the brand-gated GET /api/v1/brand/streamers/search
  # (same-origin session cookie). The page shell is public; the JS gates on /api/v1/lk/status.
  def brand_search
    @page = "brand_search"
  end

  # Brand dashboard compare (screen 23) — faithful export host. Real side-by-side columns wired
  # client-side by landing/brand_compare.js against GET /api/v1/brand/compare?channels=… (same-origin
  # session cookie). The page shell is public; the JS gates on /api/v1/lk/status.
  def brand_compare
    @page = "brand_compare"
  end

  # Brand dashboard audience overlap (screen 24) — faithful export host. Real chat-audience overlap
  # (matrix / pairwise / composition / recommendations) wired client-side by landing/brand_overlap.js
  # against GET /api/v1/brand/overlap?channels=… (same-origin cookie). Page shell public; JS gates.
  def brand_overlap
    @page = "brand_overlap"
  end

  # Brand dashboard streamer card (screen 21) — faithful export host. Real 4-layer verification wired
  # client-side by landing/brand_streamer_card.js against GET /api/v1/brand/streamers/:login/card
  # (same-origin cookie). Page shell public; JS gates on /api/v1/lk/status.
  def brand_streamer_card
    @page = "brand_streamer_card"
    @login = params[:login]
  end

  private

  # Marketing pages must reach the widest possible audience — opt out of the
  # app-wide `allow_browser versions: :modern` guard (no 406 for old browsers).
  def browser_guard_enabled?
    false
  end
end
