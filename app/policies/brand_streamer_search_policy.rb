# frozen_string_literal: true

# Brand streamer search (screen 20): requires brand access (business tier or active business-team).
# Non-brand → Pundit denial → SUBSCRIPTION_REQUIRED on the dashboard surface. Mirrors the other brand
# policies (#341/#348/#350). brand? is inherited from ApplicationPolicy.
class BrandStreamerSearchPolicy < ApplicationPolicy
  def index?
    brand?
  end
end
