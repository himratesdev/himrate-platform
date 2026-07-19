# frozen_string_literal: true

# T1-074 (TI v2) — configurable engine constant (φ_yellow/φ_red, q_mid/q_hi, τ_hard/τ_delta, π0,
# f_self_yellow/f_self_red, z*/g*, LLR-table keys). SRS §5.1 / FR-016 / ADR DEC-3 (calibration
# decoupled from code). Flat key→value store (UNIQUE key) — φ/τ are GLOBAL scalars; per-cell ρ*
# lives in CalibrationCellBaseline, not here. Values ILLUSTRATIVE until GATE 0 (`source`
# 'illustrative', `calibrated=false`); Calibration::IngestHoldoutJob (FR-016) rewrites them and
# flips calibrated=true. The engine READS these — never hardcodes thresholds — so recalibration is
# a data update, not a redeploy.
class CalibrationConstant < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :value, presence: true, numericality: true
  validates :source, presence: true

  # Resolve a constant by key. A missing key returns `fallback` so a half-seeded env degrades, not
  # crashes (raises nothing).
  def self.value_for(key, fallback: nil)
    where(key: key).limit(1).pick(:value) || fallback
  end
end
