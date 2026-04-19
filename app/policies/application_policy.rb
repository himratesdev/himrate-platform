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

    streamer_on_channel?(channel)
  end

  # TASK-039 FR-011: Trends-scoped predicate использует memoized user.streamer_twitch_ids
  # (FR-039) для устранения N+1 при batched policy calls (10 Trends endpoints).
  # owns_channel? делегирует сюда же — единая точка для streamer-ownership проверки.
  def streamer_on_channel?(channel)
    return false unless registered?

    user.streamer_twitch_ids.include?(channel.twitch_id)
  end

  def channel_tracked?(channel)
    user.tracked_channels
        .joins(:subscription)
        .where(channel: channel, tracking_enabled: true)
        .where(subscriptions: { is_active: true })
        .exists? ||
      channel_in_grace_period?(channel)
  end

  def channel_in_grace_period?(channel)
    user.tracked_channels
        .joins(:subscription)
        .where(channel: channel, tracking_enabled: true)
        .where(subscriptions: { is_active: false })
        .where("subscriptions.cancelled_at > ?", 7.days.ago)
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

  # TASK-032 PG WARNING #1: Consolidated — single source of truth
  def post_stream_window_open?(channel)
    PostStreamWindowService.open?(channel)
  end
end
