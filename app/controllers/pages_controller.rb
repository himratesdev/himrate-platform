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

  private

  # Marketing pages must reach the widest possible audience — opt out of the
  # app-wide `allow_browser versions: :modern` guard (no 406 for old browsers).
  def browser_guard_enabled?
    false
  end
end
