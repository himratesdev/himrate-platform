# frozen_string_literal: true

# Discovery surfaces.
class DiscoverPolicy < ApplicationPolicy
  # Screen 04 «Куда пойти» / the home page's live board — which channels are live right now and what
  # their public headline verdict is. Every value on it is already free on each channel's card, so
  # the board is open to guests too; personalisation (is_watched_by_user) exists only when a real
  # user is present. Headless record (:discover symbol).
  def live?
    true
  end

  # Screen 13 «Рост» — game opportunities for the signed-in user's own growth planning. Stays
  # registered-only (any registered user, no paywall); only the live board opened to guests.
  def games?
    registered? && record == user
  end
end
