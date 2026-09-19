# frozen_string_literal: true

# Free-text channel search: open to everyone, guests included. Finding a channel by nickname is
# navigation, not a paid analytic — the paywalls sit on what you see AFTER you land on it, and the
# home page cannot exist without it. Headless record (:search symbol). The anonymous request
# budget is a Rack::Attack concern ("public_discovery/ip"), not an authorization one.
class SearchPolicy < ApplicationPolicy
  def search?
    true
  end
end
