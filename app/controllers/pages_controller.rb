# frozen_string_literal: true

# Faithful Rails host of the Pencil export (TASK-060). Serves two surfaces on two layouts:
#   - the public MARKETING site + the public channel card → `landing` layout (SEO head, marketing JS)
#   - the product / LK (login + /app/* dashboards) → `app` layout (noindex, no marketing canvas/nav)
# resolve_layout picks per request. This is the seam for the app.himrate.com subdomain split — the
# product surfaces already render on their own layout, independent of the marketing chrome. No auth —
# these are public GET shells; API / extension traffic (api/v1/*) is unaffected.
class PagesController < ApplicationController
  layout :resolve_layout

  # Subdomain host canonicalization (301): marketing surfaces belong on the apex (himrate.com,
  # SEO-indexed); the product / LK belongs on app.himrate.com (noindex). Page requests that land
  # on the wrong production host get a permanent redirect so every surface has exactly ONE
  # canonical URL. Scoped to PagesController → API / auth / og / up traffic (other controllers)
  # is never touched. Skips the staging test host and dev/localhost.
  before_action :canonicalize_host

  PAGES = %w[index streamers brands viewers methodology login].freeze

  # One action per page; @page selects the per-page JS bundle in the layout.
  PAGES.each do |page|
    define_method(page) { @page = page }
  end

  # Public channel card (screen 02) — faithful export host. Real data is wired client-side by
  # landing/channel_card.js against the public GET /api/v1/channels/:login/card (headline +
  # reputation are free on any channel per access-model v2). No auth.
  def channel_card
    # Only render the card for a channel we actually hold — the card API 404s for
    # unknown logins anyway, so a bare shell for any string was a soft-404 + indexable
    # empty page. 404 unknown channels instead (no SEO junk). (landing hardening)
    unless Channel.exists?(login: params[:login])
      return render(file: Rails.public_path.join("404.html"), status: :not_found, layout: false)
    end

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

  # Streamer grow (screen 13) — faithful export host. Real game opportunities wired client-side by
  # landing/grow.js against GET /api/v1/discover/games (PO spec: Steam novelty × scarcity ×
  # distribution). Own-channel goal banner from the public card headline.
  def grow
    @page = "grow"
    @brand_dashboard = true
  end

  # Streamer cross-platform socials (screen 50 «Мои соцсети») — faithful export host. Real DESCRIPTIVE
  # analytics (subs / reach / ER / growth) of the streamer's linked platforms wired client-side by
  # landing/my_socials.js against GET /api/v1/social/streamers/:login (login = own twitch_login from
  # /user/me). NO fraud/накрутка verdict on socials (PO 2026-07-21) — Trust-Score/real-audience heroes
  # are hidden; Telegram + YouTube populate, VK/IG/TT are footprint-known but metrics-deferred.
  def my_socials
    @page = "my_socials"
    @brand_dashboard = true
  end

  # Brand-side blogger social profile (screen 61) — the brand's descriptive cross-platform view of ANY
  # streamer (login from the path). Same keyless engine as screen 50 (GET /api/v1/social/streamers/:login
  # + /attribution), wired client-side by landing/blogger_profile.js. Brand-gated shell (JS gates on
  # /api/v1/lk/status). Fraud/«bot-corrected»/«real audience %» blocks are stripped — descriptive only
  # (subs / reach / ER / growth / footprint); demographics / geo / посты / прогноз цен honest-deferred.
  def blogger_profile
    @page = "blogger_profile"
    @login = params[:login]
    @brand_dashboard = true
  end

  # Brand creator discovery (screen 60) — faithful export host wired by landing/brand_creators.js
  # to the EXISTING brand streamer search (GET /api/v1/brand/streamers/search — real 30-day audience,
  # already scale-correct to ~10k channels). Result card → the cross-platform blogger profile
  # (screen 61, /app/blogger/:login). No new backend. Fraud elements (fake-%, price, social-ER) and the
  # social-platform / topic filter chips (need a footprint index / taxonomy) are stripped / deferred.
  def brand_creators
    @page = "brand_creators"
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

  # A page request is a PRODUCT surface iff its path is the login page or under /app/*. Everything
  # else PagesController serves (the marketing pages + the public channel card /c/:login) is
  # marketing. This mirrors #resolve_layout but is PATH-based (not action/@page-based) because the
  # before_action runs before the action body sets @page — and path rules can't drift out of sync
  # as new actions are added. Redirect only fires on the real production himrate.com hosts; the
  # staging test host serves every surface unredirected, and dev/localhost is left alone.
  APP_HOST  = "app.himrate.com"
  APEX_HOST = "himrate.com"

  def canonicalize_host
    host = request.host
    return unless host == APEX_HOST || host.end_with?(".himrate.com")
    return if host == "staging.himrate.com"

    product = request.path == "/login" || request.path.start_with?("/app/")
    target  = product ? APP_HOST : APEX_HOST
    return if host == target

    redirect_to "https://#{target}#{request.fullpath}",
                status: :moved_permanently, allow_other_host: true
  end

  # The product surfaces — login + the /app/* dashboards (@brand_dashboard) — render on the `app`
  # layout (noindex, product chrome). Everything else the marketing landing serves — the marketing
  # pages + the public channel card /c/:login — stays on the SEO-rich `landing` layout.
  def resolve_layout
    return "app" if @page == "login" || @brand_dashboard

    "landing"
  end

  # Marketing pages must reach the widest possible audience — opt out of the
  # app-wide `allow_browser versions: :modern` guard (no 406 for old browsers).
  def browser_guard_enabled?
    false
  end
end
