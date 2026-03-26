# frozen_string_literal: true

class ChannelPolicy < ApplicationPolicy
  def index?
    registered?
  end

  def show?
    true
  end

  def create?
    registered?
  end

  def destroy?
    return false unless registered?

    channel_tracked?(record)
  end
end
