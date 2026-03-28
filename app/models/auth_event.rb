# frozen_string_literal: true

class AuthEvent < ApplicationRecord
  PROVIDERS = %w[twitch google].freeze
  RESULTS = %w[attempt success failure].freeze

  belongs_to :user, optional: true

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :result, presence: true, inclusion: { in: RESULTS }
  validates :created_at, presence: true

  scope :failures, -> { where(result: "failure") }
  scope :recent, ->(duration = 10.minutes) { where(created_at: duration.ago..) }
  scope :by_ip, ->(ip) { where(ip_address: ip) }
  scope :by_provider, ->(provider) { where(provider: provider) }
end
