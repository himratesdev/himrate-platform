# frozen_string_literal: true

class ScoreDispute < ApplicationRecord
  RESOLUTION_STATUSES = %w[pending reviewing resolved rejected].freeze

  belongs_to :user
  belongs_to :channel

  validates :reason, presence: true
  validates :submitted_at, presence: true
  validates :resolution_status, inclusion: { in: RESOLUTION_STATUSES }
end
