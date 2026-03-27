# frozen_string_literal: true

class Notification < ApplicationRecord
  self.inheritance_column = nil

  NOTIFICATION_TYPES = %w[
    stream_ended post_stream_available post_stream_expiring
    anomaly_detected subscription_expiring weekly_digest
  ].freeze

  belongs_to :user
  belongs_to :channel, optional: true
  belongs_to :stream, optional: true

  validates :type, presence: true, inclusion: { in: NOTIFICATION_TYPES }
end
