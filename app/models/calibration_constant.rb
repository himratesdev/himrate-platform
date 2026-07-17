# frozen_string_literal: true

# T1-074 (TI v2) — configurable engine constant (φ_yellow/φ_red, τ_hard, LLR weights, Q/z*/g* …).
# ADR DEC-3 (calibration decoupled from code). Values are ILLUSTRATIVE until GATE 0 ingests the
# labeled hold-out (calibrated=false). Looked up by name+category; the engine reads these, never
# hardcodes thresholds — so recalibration is a data update, not a redeploy.
class CalibrationConstant < ApplicationRecord
  DEFAULT_CATEGORY = "default"

  validates :param_name, presence: true, uniqueness: { scope: :category }
  validates :category, presence: true
  validates :param_value, presence: true, numericality: true

  # Resolve a constant, falling back to the "default" category, then to the caller-supplied default.
  # Raises nothing — a missing constant returns `fallback` so a half-seeded env degrades, not crashes.
  def self.value_for(param_name, category: DEFAULT_CATEGORY, fallback: nil)
    where(param_name: param_name, category: [ category, DEFAULT_CATEGORY ])
      .order(Arel.sql("category = #{connection.quote(category)} DESC"))
      .limit(1)
      .pick(:param_value) || fallback
  end
end
