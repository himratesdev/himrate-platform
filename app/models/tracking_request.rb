# frozen_string_literal: true

# TASK-034 FR-025: Request to start tracking an untracked channel.
# channel_login is VARCHAR (not FK) because the channel may not exist in our DB.
class TrackingRequest < ApplicationRecord
  belongs_to :user, optional: true

  validates :channel_login, presence: true, length: { maximum: 50 }
  validates :status, presence: true, inclusion: { in: %w[pending approved rejected] }
  validates :channel_login, uniqueness: {
    scope: :user_id,
    conditions: -> { where.not(user_id: nil) },
    message: :already_requested
  }

  validate :must_have_identifier

  scope :pending, -> { where(status: "pending") }
  scope :for_channel, ->(login) { where(channel_login: login.downcase) }

  before_validation :normalize_channel_login

  private

  def must_have_identifier
    if user_id.blank? && extension_install_id.blank?
      errors.add(:base, :identifier_required)
    end
  end

  def normalize_channel_login
    self.channel_login = channel_login&.downcase&.strip
  end
end
