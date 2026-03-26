# frozen_string_literal: true

class WatchlistPolicy < ApplicationPolicy
  def index?
    registered?
  end

  def create?
    registered?
  end

  def destroy?
    return false unless registered?

    record.user_id == user.id
  end
end
