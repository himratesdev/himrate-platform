# frozen_string_literal: true

# Brand streamer card (screen 21): independent 30-day track-record verification of a streamer
# before a deal. Brand-gated (business tier or active business-team). Non-brand → Pundit denial →
# SUBSCRIPTION_REQUIRED on the dashboard surface (via Api::BaseController error resolution).
# brand? is inherited from ApplicationPolicy. Mirrors BrandOverlapPolicy (#341, screen 24).
class BrandStreamerCardPolicy < ApplicationPolicy
  def show?
    brand?
  end
end
