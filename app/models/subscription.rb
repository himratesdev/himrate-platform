# frozen_string_literal: true

class Subscription < ApplicationRecord
  belongs_to :user
  has_many :tracked_channels, dependent: :nullify
end
