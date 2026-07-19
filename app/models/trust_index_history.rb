# frozen_string_literal: true

# TASK-029: Trust Index Engine output record.

class TrustIndexHistory < ApplicationRecord
  CLASSIFICATIONS = %w[trusted needs_review suspicious fraudulent].freeze
  COLD_START_STATUSES = %w[insufficient provisional_low provisional full deep].freeze

  belongs_to :channel
  belongs_to :stream, optional: true

  # trust_index_score is retired under the v2 engine (fraud = ERV = V − F̂, no TI-scalar) — only v1
  # rows still carry it, so the presence requirement is v1-only (T1-074 / ADR DEC-3). v2 rows persist
  # the ERV/band/axes columns instead; classification/cold_start_status stay null on v2.
  validates :trust_index_score, presence: true, if: :v1_engine?
  validates :calculated_at, presence: true
  validates :classification, inclusion: { in: CLASSIFICATIONS }, allow_nil: true
  validates :cold_start_status, inclusion: { in: COLD_START_STATUSES }, allow_nil: true

  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
  scope :latest_for_channel, ->(channel_id) { for_channel(channel_id).order(calculated_at: :desc).first }

  private

  # Legacy v1 rows require the retired TI-scalar; v2 rows (engine_version='v2') do not.
  def v1_engine?
    engine_version.nil? || engine_version == "v1"
  end
end
