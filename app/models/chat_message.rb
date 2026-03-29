# frozen_string_literal: true

# TASK-024: Enhanced with IRC fields.
# stream_id is optional (messages may arrive before stream record exists).

class ChatMessage < ApplicationRecord
  belongs_to :stream, optional: true

  MSG_TYPES = %w[
    privmsg sub resub subgift submysterygift raid bitsbadgetier
    ritual announcement roomstate clearchat clearmsg usernotice
  ].freeze

  validates :username, presence: true, length: { maximum: 255 }, unless: -> { msg_type.in?(%w[roomstate]) }
  validates :channel_login, presence: true, length: { maximum: 255 }
  validates :msg_type, presence: true, inclusion: { in: MSG_TYPES }
  validates :timestamp, presence: true
  validates :color, length: { maximum: 7 }, allow_nil: true
  validates :display_name, length: { maximum: 255 }, allow_nil: true
  validates :badge_info, length: { maximum: 255 }, allow_nil: true
  validates :twitch_msg_id, length: { maximum: 255 }, allow_nil: true

  scope :for_channel, ->(login) { where(channel_login: login) }
  scope :for_stream, ->(stream_id) { where(stream_id: stream_id) }
  scope :privmsgs, -> { where(msg_type: "privmsg") }
  scope :usernotices, -> { where(msg_type: MSG_TYPES - %w[privmsg roomstate clearchat clearmsg]) }
  scope :in_timerange, ->(from, to) { where(timestamp: from..to) }
end
