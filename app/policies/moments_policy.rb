# frozen_string_literal: true

# Screen 07 «Лучшие моменты» — chat-peak moments of finished streams. Viewer-free (any registered
# user, access-model v2): the moments derive from the same public chat-analytics the card shows.
class MomentsPolicy < ApplicationPolicy
  def index?
    registered? && record == user
  end
end
