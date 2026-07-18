# frozen_string_literal: true

# Brand-side audience overlap (screen 24): requires brand access (business tier or active
# business-team). Non-brand → Pundit denial → SUBSCRIPTION_REQUIRED on the dashboard surface
# (via ApplicationController error resolution). brand? is inherited from ApplicationPolicy.
class BrandOverlapPolicy < ApplicationPolicy
  def index?
    brand?
  end
end
