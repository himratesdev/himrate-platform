# frozen_string_literal: true

module Auth
  # T1-060 FR-5: the surface a request comes from (the Chrome extension vs the SaaS
  # dashboard / ЛК), carried as the JWT `aud` claim and wrapped together with the user as
  # Pundit's pundit_user. Policies read `surface` to decide whether a tier-paywall denial
  # becomes SUBSCRIPTION_REQUIRED (dashboard) or an honest-empty data-state (extension).
  # Absent/blank surface defaults to EXTENSION (the safe, no-paywall surface, BR-8).
  #
  # Plain class (not Struct.new(...) { ... }) on purpose: constants defined inside a
  # Struct block land in the enclosing lexical scope (Auth::), not on the struct, so
  # Auth::AuthContext::EXTENSION would be undefined. A normal class body scopes them here.
  class AuthContext
    EXTENSION = "extension"
    DASHBOARD = "dashboard"

    attr_reader :user

    def initialize(user, surface)
      @user = user
      @surface = surface
    end

    def surface
      @surface.presence || EXTENSION
    end

    def extension?
      surface == EXTENSION
    end

    def dashboard?
      surface == DASHBOARD
    end
  end
end
