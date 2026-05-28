# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 (FR-016): durable state record per-user для cold-start enrollment backfill.
# Mediates с Redis hash `pva:backfill:{user_id}` через PersonalAnalytics::Enrollment::StateStore PORO.
# Wave 1 sources active: #1 (Helix follows) · #2 (anon GQL ChannelShell) · #5 (Apollo cache walk).
# Sources #3 (CH chat_messages) + #4 (GQL self-subs) deferred per ADR v3.0 wave-doctrine.
class PvaEnrollmentBackfillState < ApplicationRecord
  self.table_name = "pva_enrollment_backfill_state"

  belongs_to :user

  STATUSES = %w[pending in_progress partial done partial_timeout failed].freeze
  SOURCE_KEYS = %w[source_1 source_2 source_3 source_4 source_5].freeze

  validates :overall_status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: true

  scope :pending_or_in_progress, -> { where(overall_status: %w[pending in_progress partial]) }
  scope :stuck, ->(threshold = 10.minutes.ago) {
    pending_or_in_progress.where("oauth_linked_at < ?", threshold)
  }

  # Returns true if previous backfill is recent enough to skip re-enrollment (BR-015: skip <30 days).
  def recent_completion?
    return false unless completed_at
    completed_at > 30.days.ago
  end
end
