# frozen_string_literal: true

# TASK-110 FR-014..017: Pundit gate для clip transcript requests.
# Free tier: 10 transcripts/calendar month (per `bft/ext/PRICING.md` BR-005).
# Premium tier: unlimited (FR-017).
# Business tier: unlimited (inherits Premium permissions, incl. team-derived).
#
# Single-source-of-truth paywall: premium/business access derives from `user.tier`
# via ApplicationPolicy#premium? / #effective_business? — NOT the dead
# `users.premium_active` column (never written by any code; defaults false).
class ClipTranscriptPolicy < ApplicationPolicy
  FREE_MONTHLY_LIMIT = 10

  def create?
    return false unless registered?
    return true if clip_premium?

    ClipTranscriptRequest.month_count_for(user) < FREE_MONTHLY_LIMIT
  end

  def show?
    registered?
  end

  def index?
    return false unless registered?

    clip_premium?
  end

  def remaining_for(user_arg = user)
    return Float::INFINITY if clip_premium?

    [ FREE_MONTHLY_LIMIT - ClipTranscriptRequest.month_count_for(user_arg), 0 ].max
  end

  private

  # Premium clip access = canonical Premium tier OR effective Business (own + team).
  def clip_premium?
    premium? || effective_business?
  end
end
