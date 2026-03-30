# frozen_string_literal: true

class User < ApplicationRecord
  include Flipper::Identifier
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
  has_many :team_memberships, dependent: :destroy
  has_many :owned_team_memberships, class_name: "TeamMembership", foreign_key: :team_owner_id, dependent: :destroy

  VALID_LOCALES = %w[en ru].freeze

  validates :role, inclusion: { in: %w[viewer streamer] }
  validates :tier, inclusion: { in: %w[free premium business] }
  validates :locale, inclusion: { in: VALID_LOCALES }, allow_nil: true
  validates :avatar_url, format: { with: /\Ahttps?:\/\//i, message: "must be a valid URL" }, allow_blank: true

  scope :active, -> { where(deleted_at: nil) }
end
