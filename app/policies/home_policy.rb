# frozen_string_literal: true

# LK-BACKEND Wave 1b: Home (recent channels + live-from-watchlists). Ownership-only, all-free
# (no paywall) — the controller is always scoped to current_user. record = current_user.
# Mirrors PersonalAnalyticsPolicy (own-data, registered-only).
class HomePolicy < ApplicationPolicy
  def recent?
    own?
  end

  def track_recent?
    own?
  end

  def live_channels?
    own?
  end

  private

  def own?
    registered? && record == user
  end
end
