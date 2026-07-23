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
      llr_per_user_bot_score: 3.90, llr_known_bot: 3.40,
      # TI v2.1 inflation-event corroborator (BUG-A/BUG-B pivot, 2026-07-22). Gives F_soft's
      # silent-viewbot deficit an INDEPENDENT second corroborator (C_inflation) so it can escalate
      # AMBER→YELLOW/RED, breaking the C_hard monoculture. Driven by the calibrated v1
      # CcvChatCorrelation signal (CCV↑ ∧ chat-flat = silent injection — CCV-shape, names nobody).
      # phi_inflation = CcvChatCorrelation value threshold. inflation_corrob_enabled is a bool-as-float
      # kill-switch: 0.0 (DEFAULT, DORMANT) → C_inflation never fires → band table byte-identical to
      # today. The PO-gated flip (after BUG-A lands + phi_inflation calibrated on the honest-anchor
      # firing rate) is a data update (set enabled→1.0), no redeploy (ADR DEC-3).
      phi_inflation: 0.30, inflation_corrob_enabled: 0.0,
      # TI v2.1 i_event self-history tripwire (C_self / F_self arm — the SECOND independent corroborator,
      # G-monoculture fix, T1-074 i_event EPIC 2026-07-23). i_event_enabled is a bool-as-float kill-switch:
      # 0.0 (DEFAULT, DORMANT) => engine derive_i_event returns false before reading any ie_* input =>
      # i_event=false everywhere => corroborated?, F_self eligibility, band rows all byte-identical to today.
      # The 4 ie_* floors gate external conjuncts [2/4/5/6]. Primary dormancy is the i_event_enabled=0.0
      # gate. The accidental-early-flip BACKSTOP (i_event cannot accuse before honest-corpus calibration
      # writes real floors) rests on [4] chat-share and [6] CoV being UNCONDITIONALLY non-negative → both
      # < their 0.0 defaults is impossible → the [2]∧[4]∧[5]∧[6] AND can never be true at defaults. [2]'s
      # z=99 is also never-fire (a MAD>0 guard makes 99·MAD unreachable); [5]'s -1.0 is recall-permissive
      # (a follower-crash could cross it) but [4]/[6] block the AND regardless. ⚠ Do NOT calibrate a
      # positive [4] (ie_arrival_floor_frac) or [6] (ie_cv_floor) floor BEFORE [2]/[5] — that lifts the
      # backstop. PO-gated flip (after the BUG-A windowing flip + honest-FP=0 calibration) = data update
      # (enabled=>1.0), no redeploy (DEC-3).
      i_event_enabled: 0.0,
      ie_v_trend_z: 99.0, ie_arrival_floor_frac: 0.0, ie_conv_floor: -1.0, ie_cv_floor: 0.0
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
