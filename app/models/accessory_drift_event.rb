# frozen_string_literal: true

# BUG-010 PR2: drift event between declared (deploy.yml) и runtime (kamal accessory details).
# Worker AccessoryDriftDetectorWorker opens новый event на mismatch (idempotent — partial unique
# index prevents duplicate open events per pair). Closes (status=resolved + resolved_at) when
# detection cycle finds match.

class AccessoryDriftEvent < ApplicationRecord
  STATUSES = %w[open resolved].freeze

  has_many :auto_remediation_logs, foreign_key: :drift_event_id, dependent: :nullify
  has_many :downtime_events, class_name: "AccessoryDowntimeEvent",
           foreign_key: :drift_event_id, dependent: :nullify

  validates :destination, :accessory, :declared_image, :runtime_image, :detected_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :resolved_at, presence: true, if: -> { status == "resolved" }

  scope :open_events, -> { where(status: "open") }
  scope :for_pair, ->(destination, accessory) { where(destination: destination, accessory: accessory) }

  def open?
    status == "open"
  end

  def mttr_seconds
    return unless resolved_at
    (resolved_at - detected_at).to_i
  end
end
