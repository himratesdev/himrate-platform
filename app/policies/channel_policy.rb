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

  # TASK-031 FR-008: Serializer view selection — single source of truth for tier-scoped fields.
  def serializer_view
    return :headline unless registered?

    if premium_access_for?(record)
      :full
    elsif channel_live?(record) || post_stream_window_open?(record)
      :drill_down
    else
      :headline
    end
  end

  private

  def channel_live?(channel)
    channel.streams.where(ended_at: nil).exists?
  end
end
