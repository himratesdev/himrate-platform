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
    @brand_dashboard = true
  end

  # Brand dashboard compare (screen 23) — faithful export host. Real side-by-side columns wired
  # client-side by landing/brand_compare.js against GET /api/v1/brand/compare?channels=… (same-origin
  # session cookie). The page shell is public; the JS gates on /api/v1/lk/status.
  def brand_compare
    @page = "brand_compare"
    @brand_dashboard = true
  end

  # Brand dashboard audience overlap (screen 24) — faithful export host. Real chat-audience overlap
  # (matrix / pairwise / composition / recommendations) wired client-side by landing/brand_overlap.js
  # against GET /api/v1/brand/overlap?channels=… (same-origin cookie). Page shell public; JS gates.
  def brand_overlap
    @page = "brand_overlap"
    @brand_dashboard = true
  end

  # Brand dashboard streamer card (screen 21) — faithful export host. Real 4-layer verification wired
  # client-side by landing/brand_streamer_card.js against GET /api/v1/brand/streamers/:login/card
  # (same-origin cookie). Page shell public; JS gates on /api/v1/lk/status.
  def brand_streamer_card
    @page = "brand_streamer_card"
    @login = params[:login]
    @brand_dashboard = true
  end

  # Viewer dashboard home (screen 01) — faithful export host. Real recent + live-from-watchlists
  # channels wired client-side by landing/viewer_home.js against GET /api/v1/me/home/* (same-origin
  # cookie). @brand_dashboard loads the shared LK sidebar/topbar chrome (landing/brand_nav.js).
  def viewer_home
    @page = "viewer_home"
    @brand_dashboard = true
  end

  # Viewer watchlists (screen 05) — faithful export host. Real lists + channels + create/rename/delete
  # + add/remove wired client-side by landing/watchlists.js against GET/POST/PATCH/DELETE
  # /api/v1/watchlists(/:id/channels) (same-origin cookie). @brand_dashboard loads the shared nav.
  def watchlists
    @page = "watchlists"
    @brand_dashboard = true
  end

  # Viewer settings (screen 06) — faithful export host. Real privacy toggles (GET/PUT /me/privacy,
  # canonical M15 labels) + connected accounts (GET /user/me) wired client-side by landing/settings.js.
  # TG-bot / sync-frequency have no backend yet → honestly deferred in the JS.
  def settings
    @page = "settings"
    @brand_dashboard = true
  end

  # Viewer personal activity (screen 03, PVA M-modules) — faithful export host. Real analytics wired
  # client-side by landing/my_activity.js against GET /api/v1/me/analytics/* (ownership-free).
  def my_activity
    @page = "my_activity"
    @brand_dashboard = true
  end

  # Viewer discover «Куда пойти» (screen 04) — faithful export host. Real live-now channels ranked
  # by real audience wired client-side by landing/discover.js against GET /api/v1/discover/live.
  def discover
    @page = "discover"
    @brand_dashboard = true
  end

  # Streamer own-channel dashboard (screen 10) — faithful export host. Detects the signed-in
  # streamer's channel via /api/v1/user/me (twitch_login) client-side; real card/trends/reputation
  # wired by landing/my_channel.js from the public channel analytics API.
  def my_channel
    @page = "my_channel"
    @brand_dashboard = true
  end

  # Viewer best-moments (screen 07) — faithful export host. Real chat-peak moments + window clips
  # wired client-side by landing/moments.js against GET /api/v1/me/moments (channel from
  # ?login= or the user's own/recent channels).
  def moments
    @page = "moments"
    @brand_dashboard = true
  end

  # Legal pages (Privacy Policy + Terms). Own minimal readable layout (no Pencil JS).
  # Required for Chrome Web Store submission + footer trust links.
  def privacy
    render layout: "legal"
  end

  def terms
    render layout: "legal"
  end

  private

  # Marketing pages must reach the widest possible audience — opt out of the
  # app-wide `allow_browser versions: :modern` guard (no 406 for old browsers).
  def browser_guard_enabled?
    false
  end
end
