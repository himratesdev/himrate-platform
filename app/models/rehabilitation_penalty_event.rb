# frozen_string_literal: true

# TASK-038 AR-11: Explicit rehabilitation penalty state.
# Emitted when TI crosses below 50. Resolved when required clean streams completed.
# Used by TrustIndex::RehabilitationTracker.

class RehabilitationPenaltyEvent < ApplicationRecord
  belongs_to :channel
  belongs_to :applied_stream, class_name: "Stream", optional: true

  validates :initial_penalty, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validates :required_clean_streams, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :applied_at, presence: true

  scope :active, -> { where(resolved_at: nil) }
  scope :resolved, -> { where.not(resolved_at: nil) }
  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }

  def active?
    resolved_at.nil?
  end

  def self.latest_active_for(channel_id)
    for_channel(channel_id).active.order(applied_at: :desc).first
  end
end
