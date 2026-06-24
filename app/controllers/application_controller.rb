# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Public conversion surfaces (the marketing landing) opt out via #browser_guard_enabled?
  # so old browsers are not served a 406. API controllers inherit ActionController::API
  # and are unaffected by this guard entirely.
  allow_browser versions: :modern, if: :browser_guard_enabled?

  private

  # Override to false in controllers that must serve all browsers (e.g. landing).
  def browser_guard_enabled?
    true
  end
end
