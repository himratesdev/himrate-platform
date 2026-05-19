# frozen_string_literal: true

# TASK-110 FR-014: Per-user Pundit Free 10/мес counter row.
# UNIQUE (user_id, clip_transcript_id) — same user requesting same clip = 1 row (idempotency).
# Pundit#create? counts requests in current calendar month.
class ClipTranscriptRequest < ApplicationRecord
  belongs_to :user
  belongs_to :clip_transcript, foreign_key: :clip_transcript_id, primary_key: :clip_id

  validates :user_id, presence: true
  validates :clip_transcript_id, presence: true, uniqueness: { scope: :user_id }
  validates :requested_at, presence: true

  scope :in_month, lambda { |reference = Time.current|
    where(requested_at: reference.beginning_of_month..reference.end_of_month)
  }

  def self.month_count_for(user)
    in_month.where(user_id: user.id).count
  end
end
