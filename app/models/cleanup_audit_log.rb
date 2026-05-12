# frozen_string_literal: true

# TASK-086 FR-031: audit trail — one row per CleanupWorker sub-run (or skip/error).
#
# status enum (int-backed, ADR-086 §4.6):
#   success = 0 — sub-run completed
#   partial = 1 — batched DELETE interrupted by statement_timeout, partial progress
#   error   = 2 — sub-run raised
#   skipped = 3 — Flipper flag :cleanup_worker off
#
# error storage is PII-safe (FR-034): error_code (string) + error_context (jsonb,
# UUID-redacted) — there is intentionally NO free-text error_message column.
#
# Retention is INDEFINITE per PO directive 2026-05-12 — CleanupWorker does NOT
# auto-delete cleanup_audit_logs rows.

class CleanupAuditLog < ApplicationRecord
  enum :status, { success: 0, partial: 1, error: 2, skipped: 3 }

  validates :run_at, presence: true
  validates :table_name, presence: true

  scope :recent_for_table, ->(table_name, limit:) {
    where(table_name: table_name).order(run_at: :desc).limit(limit)
  }
end
