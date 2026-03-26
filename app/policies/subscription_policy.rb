# frozen_string_literal: true

class SubscriptionPolicy < ApplicationPolicy
  def index?
    registered?
  end

  def create?
    registered?
  end

  def destroy?
    registered?
  end
end
