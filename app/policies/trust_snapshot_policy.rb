# frozen_string_literal: true

class TrustSnapshotPolicy < ApplicationPolicy
  def show?
    true
  end

  def full_access?
    return false unless registered?

    premium_access_for?(record)
  end

  def drill_down?
    return false if guest?
    return true if effective_business?
    return true if premium_access_for?(record)

    post_stream_window_open?(record)
  end
end
