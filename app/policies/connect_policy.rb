# frozen_string_literal: true

# ONBOARD-D0: own-connection status — ownership-only, no paywall (mirrors PersonalAnalyticsPolicy).
class ConnectPolicy < ApplicationPolicy
  def status?
    registered? && record.id == user.id
  end
end
