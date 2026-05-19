# frozen_string_literal: true

# TASK-110 FR-021..022: Pundit gate для cross-device sync API.
# Per PO Q4 directive (Privacy ALL ON 2026-05-06) + ADR-110 v1.1 SA-6: JWT-only auth для
# registered users; DNT honored via FR-028 (frontend disables sync если navigator.doNotTrack === '1').
class SyncPolicy < ApplicationPolicy
  def push?
    registered?
  end

  def pull?
    registered?
  end
end
