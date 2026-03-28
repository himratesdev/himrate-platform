# frozen_string_literal: true

class FollowerSnapshot < ApplicationRecord
  belongs_to :channel

  validates :timestamp, presence: true
  validates :followers_count, presence: true
end
