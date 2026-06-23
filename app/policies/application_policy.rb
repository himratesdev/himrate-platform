# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :record, :surface

  # T1-060 FR-5/DEC-3: duck-type the Pundit context. `authorize`/pundit_user passes an
  # Auth::AuthContext(user, surface); the ~8 controllers/services that instantiate a policy
  # directly with a bare User keep working (they are all extension-surface, the safe
  # default). User itself responds to neither :user nor :surface, so it can't misroute.
  def initialize(user_or_context, record)
    if user_or_context.respond_to?(:user) && user_or_context.respond_to?(:surface)
      @user = user_or_context.user
      @surface = user_or_context.surface
    else
      @user = user_or_context
      @surface = Auth::AuthContext::EXTENSION
    end
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

  def dashboard_surface?
    surface == Auth::AuthContext::DASHBOARD
  end

  # T1-060 FR-3: role predicates read the accumulating flags, not the legacy role scalar.
  # Orthogonal to the channel-ownership axis (owns_channel?/streamer_on_channel?), which
  # stays keyed on streamer_twitch_ids ∩ channel.twitch_id.
  def streamer?
    registered? && user.is_streamer
  end

  def brand?
    registered? && user.is_brand
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
