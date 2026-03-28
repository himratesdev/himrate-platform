# frozen_string_literal: true

class CrossChannelPresence < ApplicationRecord
  belongs_to :channel
  belongs_to :stream, optional: true

  validates :username, presence: true
  validates :first_seen_at, presence: true
  validates :last_seen_at, presence: true
end
