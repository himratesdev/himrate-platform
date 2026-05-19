# frozen_string_literal: true

# TASK-110 FR-014..017: Pundit gate для clip transcript requests.
# Free tier: 10 transcripts/calendar month (per `bft/ext/PRICING.md` BR-005).
# Premium tier: unlimited (FR-017, JWT scope premium_active=true).
# Business tier: unlimited (inherits Premium permissions).
class ClipTranscriptPolicy < ApplicationPolicy
  FREE_MONTHLY_LIMIT = 10

  def create?
    return false unless registered?
    return true if premium_active?

    ClipTranscriptRequest.month_count_for(user) < FREE_MONTHLY_LIMIT
  end

  def show?
    registered?
  end

  def index?
    return false unless registered?

    premium_active?
  end

  def remaining_for(user_arg = user)
    return Float::INFINITY if premium_active?(user_arg)

    [ FREE_MONTHLY_LIMIT - ClipTranscriptRequest.month_count_for(user_arg), 0 ].max
  end

  private

  def premium_active?(user_arg = user)
    return false unless user_arg

    user_arg.premium_active? || effective_business_for?(user_arg)
  end

  def effective_business_for?(user_arg)
    return false unless user_arg

    user_arg.tier == "business" || team_business?(user_arg)
  end

  def team_business?(user_arg)
    TeamMembership
      .where(user_id: user_arg.id, status: "active")
      .joins("INNER JOIN users AS owners ON owners.id = team_memberships.team_owner_id")
      .where(owners: { tier: "business" })
      .exists?
  end
end
