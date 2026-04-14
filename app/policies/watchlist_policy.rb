# frozen_string_literal: true

# TASK-036: Watchlist authorization — all registered users can manage their own watchlists.
class WatchlistPolicy < ApplicationPolicy
  def index?
    registered?
  end

  def create?
    registered?
  end

  def show?
    return false unless registered?

    record.user_id == user.id
  end

  def update?
    return false unless registered?

    record.user_id == user.id
  end

  def destroy?
    return false unless registered?

    record.user_id == user.id
  end
end
