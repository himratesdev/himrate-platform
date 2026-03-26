# frozen_string_literal: true

class StreamPolicy < ApplicationPolicy
  def index?
    return false if guest?
    return true if effective_business?
    return true if premium_access_for?(record)

    post_stream_window_open?(record)
  end

  def show?
    index?
  end

  private

  def post_stream_window_open?(channel)
    latest_stream = channel.streams.where.not(ended_at: nil).order(ended_at: :desc).first
    return false unless latest_stream

    next_stream = channel.streams
                         .where("started_at > ?", latest_stream.ended_at)
                         .exists?
    return false if next_stream

    latest_stream.ended_at >= 18.hours.ago
  end
end
