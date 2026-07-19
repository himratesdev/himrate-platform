# frozen_string_literal: true

module Calibration
  # Loads the TI v2 engine's scalar calibration constants from the DB (CalibrationConstant) into a
  # single immutable `k` object that L0→L4 read (SRS FR-016, ADR DEC-3/DEC-6). Values are ILLUSTRATIVE
  # until GATE 0; a missing key falls back to the illustrative default so a half-seeded env degrades,
  # not crashes. One query per load. (Per-cell ρ* baselines are read separately by CellResolver.)
  class Registry
    ILLUSTRATIVE = {
      pi0: 0.02, tau_hard: 0.90, tau_delta: 0.05,
      phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.50, q_hi: 0.80,
      llr_temporal_r2: 1.10, llr_temporal_r3: 2.20, llr_temporal_r4: 2.90, llr_temporal_r7: 4.60,
      llr_per_user_bot_score: 3.90, llr_known_bot: 3.40
    }.freeze

    K = Data.define(*ILLUSTRATIVE.keys)

    def self.load
      stored = CalibrationConstant.where(key: ILLUSTRATIVE.keys.map(&:to_s)).pluck(:key, :value).to_h
      values = ILLUSTRATIVE.each_with_object({}) do |(key, default), acc|
        acc[key] = (stored[key.to_s] || default).to_f
      end
      K.new(**values)
    end
  end
end
