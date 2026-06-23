# frozen_string_literal: true

module Auth
  # T1-060 FR-5: the surface a request comes from (the Chrome extension vs the SaaS
  # dashboard / ЛК), carried as the JWT `aud` claim and wrapped together with the user as
  # Pundit's pundit_user. Policies read `surface` to decide whether a tier-paywall denial
  # becomes SUBSCRIPTION_REQUIRED (dashboard) or an honest-empty data-state (extension).
  # Absent/unknown surface defaults to EXTENSION (the safe, no-paywall surface, BR-8).
  AuthContext = Struct.new(:user, :surface) do
    EXTENSION = "extension"
    DASHBOARD = "dashboard"

    def surface
      super.presence || EXTENSION
    end

    def extension?
      surface == EXTENSION
    end

    def dashboard?
      surface == DASHBOARD
    end
  end
end
