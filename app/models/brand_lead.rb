# frozen_string_literal: true

# W1: a B2B lead from the public /brands contact form. No uniqueness — a returning lead is a
# GOOD signal, every submit lands. status: new → contacted/closed (manual ops until the admin
# panel, TASK-150.8).
class BrandLead < ApplicationRecord
  STATUSES = %w[new contacted closed spam].freeze

  normalizes :email, with: ->(value) { value.to_s.strip.downcase }
  normalizes :name, :company, :budget, with: ->(value) { value.to_s.strip.presence }

  validates :name, presence: true, length: { maximum: 80 }
  validates :email, presence: true, length: { maximum: 255 },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :company, length: { maximum: 120 }, allow_nil: true
  validates :budget, length: { maximum: 80 }, allow_nil: true
  validates :message, length: { maximum: 2000 }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }

  scope :fresh, -> { where(status: "new").order(created_at: :desc) }
end
