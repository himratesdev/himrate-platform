# frozen_string_literal: true

# BUG-010 PR2: auto-remediation audit log + cool-down/max-attempts source.
# Cool-down: 24h sliding window per (destination, accessory). Max-attempts: 3/72h then auto-disable.

class AutoRemediationLog < ApplicationRecord
  RESULTS = %w[triggered skip_cooldown skip_max_attempts api_error auto_disabled].freeze
  COOLDOWN_WINDOW = 24.hours
  MAX_ATTEMPTS_WINDOW = 72.hours
  MAX_ATTEMPTS = 3

  belongs_to :drift_event, class_name: "AccessoryDriftEvent", optional: true

  validates :destination, :accessory, :triggered_at, :result, :attempt_number, presence: true
  validates :result, inclusion: { in: RESULTS }
  validates :attempt_number, numericality: { greater_than: 0 }

  scope :for_pair, ->(destination, accessory) { where(destination: destination, accessory: accessory) }
  scope :within_cooldown, ->(time = COOLDOWN_WINDOW.ago) { where(triggered_at: time..) }
  scope :within_max_window, ->(time = MAX_ATTEMPTS_WINDOW.ago) { where(triggered_at: time..) }
  scope :triggered, -> { where(result: "triggered") }
  scope :active, -> { where(disabled_at: nil) }

  def self.cool_down_active?(destination:, accessory:)
    for_pair(destination, accessory).triggered.within_cooldown.exists?
  end

  def self.max_attempts_exceeded?(destination:, accessory:)
    for_pair(destination, accessory).triggered.within_max_window.count >= MAX_ATTEMPTS
  end

  def self.disabled_for?(destination:, accessory:)
    for_pair(destination, accessory).where.not(disabled_at: nil).exists?
  end
end
