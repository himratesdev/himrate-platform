# frozen_string_literal: true

# TASK-031: Channel policy with track/untrack + serializer view selection.

class ChannelPolicy < ApplicationPolicy
  def index?
    registered?
  end

  def show?
    true
  end

  def create?
    registered?
  end

  def destroy?
    return false unless registered?

    channel_tracked?(record)
  end

  # TASK-031 FR-004: Track requires Premium, Business, or owns_channel (streamer data exchange)
  def track?
    return false unless registered?

    premium? || effective_business? || owns_channel?(record)
  end

  # TASK-031 FR-005: Untrack — any registered user can untrack their own tracked channel.
  # Ownership verified in controller (TrackedChannel.find_by user + channel).
  def untrack?
    registered?
  end

  # TASK-032 FR-002: Stream history — Premium tracked, Business, or Streamer own.
  def view_streams?
    return false unless registered?

    premium_access_for?(record)
  end

  # TASK-032 FR-004: Health Score — Streamer own, Premium tracked, Business.
  def view_health_score?
    return false unless registered?

    owns_channel?(record) || premium_access_for?(record)
  end

  # TASK-032 CR #4: show_trust? — always allows (headline for all), determines view level
  def show_trust?
    true
  end

  # TASK-032 CR #4: show_erv? — always allows (headline for all)
  def show_erv?
    true
  end

  # TASK-031 FR-008: Serializer view selection — single source of truth for tier-scoped fields.
  def serializer_view
    return :headline unless registered?

    if premium_access_for?(record)
      :full
    elsif record.live? || post_stream_window_open?(record)
      :drill_down
    else
      :headline
    end
  end

  # TASK-032 CR #7: Public query methods (no more policy.send(:private_method))
  def premium_access?
    premium_access_for?(record)
  end

  def effective_business_access?
    effective_business?
  end

  def owns_channel_access?
    owns_channel?(record)
  end
end
