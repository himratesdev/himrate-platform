# frozen_string_literal: true

# Public marketing landing (TASK-060). Server-rendered HTML on a dedicated
# `landing` layout. No auth — these are public GET pages. API / extension
# traffic (api/v1/*) is unaffected: this only adds top-level html routes.
class PagesController < ApplicationController
  layout "landing"

  # Landing is Russian-first (PO authors RU; EN is derived via i18n). Scope the
  # locale per request (?locale=en switches) without touching the app-wide
  # default (:en), so <html lang> matches the rendered content for SEO/a11y.
  before_action :set_landing_locale

  # Phase 0 = root smoke only. streamers / brands / viewers / methodology + legal
  # actions are added with their views in the literal-port phases.
  def index; end

  private

  # Marketing landing must reach the widest possible audience — opt out of the
  # app-wide `allow_browser versions: :modern` guard (no 406 for old browsers).
  def browser_guard_enabled?
    false
  end

  def set_landing_locale
    requested = params[:locale].to_s.to_sym
    I18n.locale = I18n.available_locales.include?(requested) ? requested : :ru
  end
end
