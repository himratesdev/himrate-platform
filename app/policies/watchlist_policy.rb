# frozen_string_literal: true

# TASK-036: Watchlist authorization — all registered users can manage their own watchlists.
# S2 CR fix: filter_channels? via Pundit (not inline).
class WatchlistPolicy < ApplicationPolicy
  def index?
    registered?
  end

  def create?
    registered?
  end

  def show?
    owner?
  end

  def update?
    owner?
  end

  def destroy?
    owner?
  end

  # S2: Filters/sort require Premium or Business — paywall via Pundit
  def filter_channels?
    return false unless owner?

    user.subscriptions.where(is_active: true).exists?
  end

  private

  def owner?
    return false unless registered?

    record.is_a?(Class) || record.user_id == user.id
  end
end
