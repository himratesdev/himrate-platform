# frozen_string_literal: true

# TASK-029: Trust Index Engine output record.

class TrustIndexHistory < ApplicationRecord
  CLASSIFICATIONS = %w[trusted needs_review suspicious fraudulent].freeze
  COLD_START_STATUSES = %w[insufficient provisional_low provisional full deep].freeze

  belongs_to :channel
  belongs_to :stream, optional: true

  validates :trust_index_score, presence: true
  validates :calculated_at, presence: true
  validates :classification, inclusion: { in: CLASSIFICATIONS }, allow_nil: true
  validates :cold_start_status, inclusion: { in: COLD_START_STATUSES }, allow_nil: true

  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
  scope :latest_for_channel, ->(channel_id) { for_channel(channel_id).order(calculated_at: :desc).first }
end
