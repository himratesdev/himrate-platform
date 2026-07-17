# frozen_string_literal: true

# T1-074 (TI v2) — immutable dispute-safe evidence backing the "Confirmed anomaly" plashka
# (SRS §5.1 / FR-009 / EC-13; ADR DEC-9). Written ONLY when C_hard fires (N_frac ≥ φ). Persists the
# exact named accounts + their p_u at flag time so a 40-day-old Score Correction dispute is
# reproducible even after the raw chat rotates or GATE 0 recalibrates τ_hard (recompute-from-raw is
# not bit-identical). The plashka MUST NOT render without backing rows (EC-13 assertion).
# Retention = the dispute window (optional score_dispute_id, N-3). Append-only — never mutated.
class NamedBotEvidence < ApplicationRecord
  belongs_to :stream
  belongs_to :score_dispute, optional: true

  validates :username, presence: true, uniqueness: { scope: :stream_id }
  validates :p_u, presence: true, numericality: { in: 0..1 }
  validates :evidence_reason, presence: true
  validates :calculated_at, presence: true

  # Immutable: block updates after creation (evidence integrity for disputes).
  before_update { raise ActiveRecord::ReadOnlyRecord, "named_bot_evidence is append-only" }

  def self.for_stream(stream_id)
    where(stream_id: stream_id).order(p_u: :desc)
  end
end
