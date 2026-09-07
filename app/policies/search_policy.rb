# frozen_string_literal: true

# Free-text channel search: available to any signed-in user. Finding a channel by nickname is
# navigation, not a paid analytic — the paywalls sit on what you see AFTER you land on it.
class SearchPolicy < ApplicationPolicy
  def search?
    registered?
  end
end
