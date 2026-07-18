# frozen_string_literal: true

# A channel the viewer opened from the ЛК (screen 01 "Недавно открытые каналы"). One row per
# (user, channel); re-opening bumps opened_at. Distinct from PVA view-events (watching a stream).
class RecentChannel < ApplicationRecord
  belongs_to :user
  belongs_to :channel

  validates :opened_at, presence: true

  # Idempotent per (user, channel): re-open just bumps opened_at (no duplicate rows). Race-safe on
  # the unique index — a concurrent first-insert loses at RecordNotUnique and re-finds + bumps.
  def self.track(user:, channel:)
    record = find_or_initialize_by(user: user, channel: channel)
    record.opened_at = Time.current
    record.save!
    record
  rescue ActiveRecord::RecordNotUnique
    find_by!(user: user, channel: channel).tap { |existing| existing.update!(opened_at: Time.current) }
  end
end
