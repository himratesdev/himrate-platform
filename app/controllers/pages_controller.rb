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
  # Header-level noindex for the two deindexed host classes. Product host: meta noindex =
  # suspenders, this header = belt (survives layout/meta drift, covers non-HTML responses).
  # WEB-CONSOLIDATION stand: robots Disallow does the work; the header is only the fallback
  # (layout metas are not host-aware and may read `follow` there — harmless behind a Disallow).
  after_action :noindex_deindexed_host

  PAGES = %w[index streamers brands viewers methodology login].freeze

  # One action per page; @page selects the per-page JS bundle in the layout.
  PAGES.each do |page|
    define_method(page) { @page = page }
  end

  # Public channel card (screen 02) — faithful export host. Real data is wired client-side by
  # landing/channel_card.js against the public GET /api/v1/channels/:login/card (headline +
  # reputation are free on any channel per access-model v2). No auth.
  # WEB-CONSOLIDATION §8: one broadcast, taken apart — the series, the anomalies, the raids and the
  # verdict at the moment it ended. A different OBJECT from the channel, hence its own page; not
  # indexed (one page per broadcast is noise), canonical points back at the channel card.
  def stream_report
    channel = Channel.find_by(login: params[:login])
    stream = channel && channel.streams.find_by(id: params[:stream_id])
    unless stream
      return render(file: Rails.public_path.join("404.html"), status: :not_found, layout: false)
    end

    @page = "stream_report"
    @login = channel.login
    @channel_name = channel.display_name.presence || channel.login
    @stream = stream
  end

  def channel_card
    # Only render the card for a channel we actually hold — the card API 404s for
    # unknown logins anyway, so a bare shell for any string was a soft-404 + indexable
    # empty page. 404 unknown channels instead (no SEO junk). (landing hardening)
    unless Channel.exists?(login: params[:login])
      return render(file: Rails.public_path.join("404.html"), status: :not_found, layout: false)
    end

    @page = "channel_card"
    @login = params[:login]
    # EPIC-64: category of the channel's latest stream, resolved against the public /top
    # registry → breadcrumb JSON-LD + a crawlable «топ категории» link (internal linking
    # /c/ ↔ /top). nil when the category doesn't qualify for a top page — link hidden.
    latest_game = Stream.where(channel_id: Channel.where(login: @login).select(:id))
                        .order(started_at: :desc).limit(1).pick(:game_name)
    @top_category = latest_game && PublicTop::Categories.all.find { |c| c[:name] == latest_game }
  end

  # EPIC-64 Phase 1 — public category-tops index (/top). Server-rendered: the page exists
  # FOR crawlers, and a client-fetch shell would hand Googlebot an empty table (the one
  # deliberate deviation from the landing client-fetch pattern). Landing layout, no auth.
  def top
    @page = "top"
    @top_categories = PublicTop::Categories.all
  end

  # EPIC-64 Phase 1 — public «Топ стримеров категории» (/top/:slug). Faithful host of the
  # Industry-Trust-Index table block from the screen-64 design with the fraud-strip canon
  # applied (Twitch-only: наблюдаемый охват + band verdict; no social scores, no «% ботов»).
  # Unknown slug 404s exactly like channel_card's unknown login (no soft-404 shells).
  def top_category
    category = PublicTop::Categories.resolve(params[:slug])
    unless category
      return render(file: Rails.public_path.join("404.html"), status: :not_found, layout: false)
    end

    @page = "top"
    @top_category = category
    @top_categories = PublicTop::Categories.all
    @top_rows = PublicTop::CategoryTop.call(category[:name])
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

  # W5 «Паутинка» — the audience-overlap graph (chat-presence basis). Real data wired
  # client-side by landing/graph.js against GET /api/v1/graph/audience (registered-gated).
  def graph
    @page = "graph"
    @brand_dashboard = true
  end

  # Business-account application (screen 72) — faithful export host, standalone (no dashboard
  # chrome). Real draft/submit wired client-side by landing/business_new.js against the singular
  # /api/v1/business_profile resource; approve/reject stay a PO runner action (TASK-150.8).
  def business_new
    @page = "business_new"
  end

  # Streamer connect onboarding (screen 11) — faithful export host. Card A = real channel
  # observation (track), Card B = Broadcaster OAuth link + granted scopes, Data Status = real
  # collection stats. Wired client-side by landing/connect.js against GET /api/v1/me/connect/status.
  def connect
    @page = "connect"
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

  # Host-aware robots.txt (moved out of public/ — a static file can't vary by host).
  # App host (SEO-hygiene 2026-09-05): ALLOW crawling — Google must be able to FETCH the
  # pages to see their noindex (meta + X-Robots-Tag); a robots Disallow blocked that and
  # left "inaccessible page" stubs piling up in Search Console. Deindexing canon: crawl
  # allowed + noindex served. Every other production host serves the marketing policy.
  APEX_ROBOTS = <<~ROBOTS.freeze
    # See https://www.robotstxt.org/robotstxt.html for documentation on how to use the robots.txt file
    User-agent: *
    Allow: /

    # Authenticated LK app shells, auth, API and internal endpoints carry no public
    # search value (also noindex'd at the page level).
    Disallow: /app/
    Disallow: /login
    Disallow: /api/
    Disallow: /dashboard
    Disallow: /po-debug
    Disallow: /health

    Sitemap: https://himrate.com/sitemap.xml
  ROBOTS
  APP_ROBOTS = "User-agent: *\nAllow: /\n"
  # The stand is a fresh, short-lived host with ZERO index history, so the «crawl allowed» canon
  # above does not apply — there is nothing indexed for a Disallow to hide. Crawl-allowed would do
  # harm instead: stand pages carry rel=canonical to the APEX (landing layout) next to their
  # noindex header, and Google may carry a noindex over to the canonical target — i.e. onto the
  # production /c/ and /top pages. Disallow keeps the crawler off the host entirely; it also
  # covers the non-PagesController surfaces (sitemap.xml, /og/*, /health) the header never reaches.
  STAND_ROBOTS = "User-agent: *\nDisallow: /\n"

  def robots
    return render(plain: STAND_ROBOTS, content_type: "text/plain") if stand_host?

    render plain: (request.host == APP_HOST ? APP_ROBOTS : APEX_ROBOTS), content_type: "text/plain"
  end

  # Legal pages (Privacy Policy + Terms). Own minimal readable layout (no Pencil JS).
  # Required for Chrome Web Store submission + footer trust links.
  def privacy
    render layout: "legal"
  end

  def terms
    render layout: "legal"
  end

  # Support / feedback (same page, both URLs are linked from the extension). Same minimal legal
  # layout as the pages above. Unlike them it is translated: this is the one public page a reader
  # reaches from inside the extension, which runs in whatever language their browser is set to, so
  # it follows the request locale (LocaleResolver — the same resolution the API uses) instead of
  # being Russian-only. with_locale, not an assignment, so nothing leaks into the next request.
  def support
    I18n.with_locale(LocaleResolver.call(request.env)) { render layout: "legal" }
  end

  private

  # Host-mapping (2026-09, canonical = app.himrate.com/<short>):
  # A page request is a PRODUCT surface iff its path is the login page, under /app/* (legacy
  # alias / staging canon), or one of the short LK paths (PRODUCT_SHORT_PATHS — must stay in
  # sync with the app-host `constraints host:` block in config/routes.rb). PATH-based (not
  # action/@page-based) because the before_action runs before the action body sets @page.
  # Redirect matrix (all 301, exactly one hop from anywhere):
  #   apex /app/x  → https://app.himrate.com/x   (strip prefix AND switch host in one hop)
  #   app  /app/x  → https://app.himrate.com/x   (strip prefix)
  #   app  /<marketing path> → apex              (unchanged)
  #   app  /       → serves LK home (routes app-host root → pages#viewer_home; no redirect)
  #   stand (STAND_HOST) /anything → skipped by this method, never redirected; WHAT exists there
  #                                   is decided by routes.rb alone (see STAND_HOST below)
  # staging.himrate.com canonicalizes like any other alias (SEO-hygiene 2026-09-05; /api/* is not
  # PagesController traffic and stays put); dev/localhost untouched.
  APP_HOST  = "app.himrate.com"
  APEX_HOST = "himrate.com"
  # WEB-CONSOLIDATION stand: the hostname where the consolidated site (one app, no landing/app
  # split) is assembled page by page against the real DB before it takes over the apex. Same web
  # container, zero runtime cost. ENV-driven (config/deploy.staging.yml env.clear) so the cutover /
  # teardown is a value change, not a code hunt; nil = no stand → every stand branch is inert.
  # What the stand serves today, unredirected: the apex-level surfaces (marketing pages, /c/, /top,
  # /login, /og, legal) and the legacy /app/* aliases — so today's LK is reachable there via /app/*.
  # The canonical SHORT LK paths (/home, /discover, …) are declared only under
  # `constraints host: "app.himrate.com"` in routes.rb and therefore 404 on the stand; the stand
  # gets its own host-constrained routes block with the first ported page (new pages override per
  # route, the rest keeps falling through).
  # What still LEAVES the stand today (known, by design — the list is not exhaustive, today's
  # pages were never written for a third host): the bare `/app` (an unconstrained route-level
  # redirect → app.himrate.com/home); a login INITIATED on the stand (the OAuth callback URIs are
  # pinned to the production hosts — log in on the app host instead: the session cookie is scoped
  # to .himrate.com and is already valid here); the two hardcoded app.himrate.com/login links in
  # the current channel card; card links from /app/graph (landing/graph.js CARD_BASE matches any
  # *.himrate.com and points at the apex). Ported pages must use relative links only.
  # Deindexing: robots Disallow (STAND_ROBOTS) first; X-Robots-Tag noindex,nofollow as the fallback.
  STAND_HOST = ENV["STAND_HOST"].presence

  # Short (prefixless) LK paths on the app host. SIMPLE heads are product as bare segments;
  # NESTED heads are product only WITH a second segment — a bare /streamers on the app host is
  # the marketing page and must bounce to the apex (the app-host route is /streamers/:login).
  PRODUCT_SHORT_HEADS_SIMPLE = %w[home search compare overlap watchlists settings activity graph connect
                                  discover channel moments grow social creators].to_set.freeze
  PRODUCT_SHORT_HEADS_NESTED = %w[streamers blogger business].to_set.freeze

  def canonicalize_host
    host = request.host
    # The stand must be skipped BEFORE anything below: the /app-prefix strip and the /login →
    # app-host rule would each bounce it off to a production host.
    return if stand_host?
    return unless host == APEX_HOST || host.end_with?(".himrate.com")
    # SEO-hygiene 2026-09-05: the staging hostname serves the SAME app/DB as production —
    # a browsable duplicate site Google was indexing («торчащие урлы»). Page requests now
    # 301 to the canonical host like any other alias; /api/* (extension staging builds)
    # is untouched — canonicalization is PagesController-scoped.

    path = request.path
    return if path == "/robots.txt" # host-aware by design — must never redirect
    if path == "/app" || path.start_with?("/app/")
      # Legacy-prefixed product path: canonical form strips the prefix and lives on the app host.
      short = path.delete_prefix("/app")
      short = "/" if short.empty?
      query = request.query_string.presence
      return redirect_to "https://#{APP_HOST}#{short}#{query ? "?#{query}" : ""}",
                         status: :moved_permanently, allow_other_host: true
    end

    product = path == "/login" || (host == APP_HOST && (path == "/" || product_short_path?(path)))
    target  = product ? APP_HOST : APEX_HOST
    return if host == target

    redirect_to "https://#{target}#{request.fullpath}",
                status: :moved_permanently, allow_other_host: true
  end

  def product_short_path?(path)
    head, rest = path.split("/", 3)[1, 2]
    return false if head.blank?
    return true if PRODUCT_SHORT_HEADS_SIMPLE.include?(head)

    PRODUCT_SHORT_HEADS_NESTED.include?(head) && rest.present?
  end

  def noindex_deindexed_host
    if stand_host?
      # nofollow too: the stand's links lead to half-assembled pages — nothing worth a crawl.
      response.set_header("X-Robots-Tag", "noindex, nofollow")
    elsif request.host == APP_HOST
      response.set_header("X-Robots-Tag", "noindex, follow")
    end
  end

  def stand_host?
    STAND_HOST.present? && request.host == STAND_HOST
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
