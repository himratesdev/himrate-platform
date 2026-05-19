# frozen_string_literal: true

# TASK-110 FR-006..007: Pundit gate для React fiber chat capture ingest.
# Per PO Q4 Privacy ALL ON 2026-05-06 + ADR-110 v1.1 SA-5: implicit для registered users.
# DNT honored frontend-side (FR-028 — extension disables capture если navigator.doNotTrack === '1').
class ChatIngestPolicy < ApplicationPolicy
  def create?
    registered?
  end
end
