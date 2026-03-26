# frozen_string_literal: true

class StreamPolicy < ApplicationPolicy
  def index?
    return false if guest?
    return true if effective_business?
    return true if premium_access_for?(record)

    post_stream_window_open?(record)
  end

  def show?
    index?
  end
end
