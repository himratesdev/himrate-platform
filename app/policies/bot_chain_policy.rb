# frozen_string_literal: true

class BotChainPolicy < ApplicationPolicy
  def show?
    true
  end

  def full_access?
    return false unless registered?

    effective_business?
  end

  def watchlist_access?
    return false unless registered?

    premium_access_for?(record)
  end
end
