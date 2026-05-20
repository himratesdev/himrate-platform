# frozen_string_literal: true

# TASK-110 FR-010..018: Whisper STT cache entity для Twitch clips.
# PK = clip_id (Twitch URL slug, e.g. "AwkwardHelplessSalamanderSwiftRage").
# Universal cache discipline (BR-006): 1 Whisper call per unique clip_id, served to all users.
#
# Phase-2 enrichment columns (sentiment_scores / ai_summary / highlights) — populated by
# TASK-103/171/172 separate epics. Frontend renders «phase 2» stub badges пока null.
class ClipTranscript < ApplicationRecord
  self.primary_key = :clip_id

  STATUSES = %w[queued processing done error].freeze

  has_many :clip_transcript_requests,
           foreign_key: :clip_transcript_id,
           primary_key: :clip_id,
           dependent: :destroy

  validates :clip_id, presence: true, length: { maximum: 255 }
  # N-2 (CR): broadcaster_id nullable until worker fetches Helix metadata; presence enforced
  # только когда transcript reaches done (worker всегда populates broadcaster_id перед done).
  validates :broadcaster_id, length: { maximum: 255 }, allow_nil: true
  validates :broadcaster_id, presence: true, if: -> { status == "done" }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :whisper_cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :done, -> { where(status: "done") }
  scope :processing, -> { where(status: %w[queued processing]) }
  scope :cached_within, ->(window) { where(cached_at: window.ago..) }

  def cache_hit?
    status == "done" && cached_at.present?
  end

  def processing?
    %w[queued processing].include?(status)
  end
end
