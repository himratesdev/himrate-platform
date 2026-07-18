# frozen_string_literal: true

# T1-074 (TI v2) — immutable dispute-safe evidence backing the "Confirmed anomaly" plashka
# (SRS §5.1 / FR-009 / EC-13 / AC-6; Glossary «B_hard»). Written ONLY when C_hard fires. Persists the
# exact named accounts + their p_u at flag time, linked to the emitting snapshot
# (`trust_index_history_id`), so a 40-day-old Score Correction dispute is reproducible even after the
# raw chat rotates or GATE 0 recalibrates τ_hard (recompute-from-raw is not bit-identical). The
# plashka MUST NOT render without backing rows (EC-13 assertion). `stream_id` is nullable — a
# live-aggregate flag has no single per-broadcast stream. Retention ≥ Rolling Window (covers the
# dispute window). Exposed ONLY to Brand-tier (paid) via `confirmed_anomaly.provenance.accounts[]`.
# Append-only — never mutated; never logged to plain app-logs (§10.3).
class NamedBotEvidence < ApplicationRecord
  belongs_to :channel
  belongs_to :stream, optional: true
  belongs_to :trust_index_history

  validates :username, presence: true
  validates :p_u, presence: true, numericality: { in: 0..1 }
  validates :evidence_reason, presence: true
  validates :calculated_at, presence: true

  # Immutable: block updates after creation (evidence integrity for disputes).
  before_update { raise ActiveRecord::ReadOnlyRecord, "named_bot_evidence is append-only" }

  # Evidence backing one snapshot's plashka, strongest posterior first.
  def self.for_history(trust_index_history_id)
    where(trust_index_history_id: trust_index_history_id).order(p_u: :desc)
  end

  # A channel's evidence over the Rolling Window, most recent first (dispute lookup).
  def self.for_channel(channel_id)
    where(channel_id: channel_id).order(calculated_at: :desc)
  end
end
