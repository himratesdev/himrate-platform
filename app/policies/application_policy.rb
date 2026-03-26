# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    false
  end

  def show?
    false
  end

  def create?
    false
  end

  def update?
    false
  end

  def destroy?
    false
  end

  private

  def guest?
    user.nil?
  end

  def registered?
    user.present?
  end

  def business?
    registered? && user.tier == "business"
  end

  def premium?
    registered? && user.tier == "premium"
  end

  def free?
    registered? && user.tier == "free"
  end

  def streamer?
    registered? && user.role == "streamer"
  end

  def owns_channel?(channel)
    return false unless streamer?

    provider = user.auth_providers.find_by(provider: "twitch")
    provider.present? && provider.uid == channel.twitch_id
  end

  def channel_tracked?(channel)
    user.tracked_channels
        .joins(:subscription)
        .where(channel: channel)
        .where(subscriptions: { status: %w[active past_due] })
        .where("subscriptions.current_period_end > ?", 7.days.ago)
        .exists?
  end

  def business_via_team?
    return false unless registered?

    TeamMembership
      .where(user_id: user.id, status: "active")
      .joins("INNER JOIN users AS owners ON owners.id = team_memberships.team_owner_id")
      .where(owners: { tier: "business" })
      .exists?
  end

  def effective_business?
    business? || business_via_team?
  end

  def premium_access_for?(channel)
    effective_business? || channel_tracked?(channel) || owns_channel?(channel)
  end
end
