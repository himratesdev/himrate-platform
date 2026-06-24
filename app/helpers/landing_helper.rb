# frozen_string_literal: true

# Centralized navigation targets for the public landing (TASK-060).
#
# Single source of truth (ADR D4): text / placement / link changes never touch
# markup — partials reference targets by key. Targets whose page or flow does not
# exist yet resolve to "#" (Phase-0 lesson: never link to a missing route → 404);
# they are wired here, in one place, as each lands in a later phase.
module LandingHelper
  LANDING_LINKS = {
    home: "/",            # root (exists)
    streamers: "#",       # → /streamers   (Phase 4 page)
    brands: "#",          # → /brands      (Phase 4 page)
    viewers: "#",         # → /viewers     (Phase 4 page)
    methodology: "#",     # → /methodology (Phase 4 page; pricing merged in)
    auth: "#",            # → web OAuth sign-in flow (not built yet)
    app: "#",             # → /app dashboard (not built yet)
    extension: "#"        # → Chrome Web Store listing (not published yet)
  }.freeze

  def landing_link(key)
    LANDING_LINKS.fetch(key)
  end

  # Server-side locale switch target (?locale=ru|en) preserving the current path.
  def landing_locale_url(locale)
    "#{request.path}?locale=#{locale}"
  end
end
