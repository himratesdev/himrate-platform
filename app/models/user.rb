# frozen_string_literal: true

class User < ApplicationRecord
  has_many :auth_providers, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :tracked_channels, dependent: :destroy
  has_many :channels, through: :tracked_channels
  has_many :watchlists, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :score_disputes, dependent: :destroy
  has_many :pdf_reports, dependent: :destroy
  has_many :api_keys, dependent: :destroy

  validates :role, inclusion: { in: %w[viewer streamer] }
  validates :tier, inclusion: { in: %w[free premium business] }

  scope :active, -> { where(deleted_at: nil) }
end
