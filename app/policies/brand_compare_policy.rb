# frozen_string_literal: true

# Brand compare (screen 23): requires brand access (business tier or active business-team). Non-brand
# → Pundit denial → SUBSCRIPTION_REQUIRED on the dashboard surface. Mirrors BrandOverlapPolicy (#341)
# and BrandStreamerCardPolicy (#348). brand? is inherited from ApplicationPolicy.
class BrandComparePolicy < ApplicationPolicy
  def index?
    brand?
  end
end
