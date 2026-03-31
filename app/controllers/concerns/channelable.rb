# frozen_string_literal: true

# TASK-032 CR #5: DRY — shared channel lookup across controllers.
# UUID / login / twitch_id detection in one place.

module Channelable
  extend ActiveSupport::Concern

  private

  def set_channel
    @channel = find_channel_by_param
  end

  def find_channel_by_param
    id = params[:channel_id] || params[:id]

    if params[:twitch_id].present?
      Channel.find_by!(twitch_id: params[:twitch_id])
    elsif params[:login].present?
      Channel.find_by!(login: params[:login])
    elsif uuid?(id)
      Channel.find(id)
    else
      Channel.find_by!(login: id)
    end
  end

  def uuid?(value)
    value.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end
end
