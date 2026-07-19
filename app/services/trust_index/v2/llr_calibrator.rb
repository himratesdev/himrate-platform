# frozen_string_literal: true

module TrustIndex
  module V2
    # L0 LLR calibration — maps a chatter's raw identity signals to the summed log-odds contribution
    # Σ_k L_k(u) (SRS FR-001, Glossary «bot_score (p_u)»; 07.1 §5.5–5.11). Each source's calibrated LLR
    # is looked up from the injected constants; a SILENT source contributes 0 (neutral — no
    # renormalization, no "clean credit"). Anti-bot signals (partner/mod/sub/…) contribute NEGATIVE
    # LLR. Pure function (constants injected, not queried) → unit-testable without the DB. The exact
    # per-source curve is GATE-0-calibrated (isotonic/Platt); this is the structural sum.
    class LlrCalibrator
      # signals — responds to: temporal_recurrence (Integer R or nil), known_bot_hit (bool),
      #   per_user_bot_score (Float 0–1 or nil), account_profile_llr (Float, pre-calibrated),
      #   anti_bot_llr (Float ≤ 0).
      # k — LLR table: llr_temporal_r2/r3/r4/r7, llr_per_user_bot_score, llr_known_bot.
      def self.sum_llr(signals, k:)
        temporal(signals, k) +
          (signals.known_bot_hit ? k.llr_known_bot : 0.0) +
          per_user(signals, k) +
          signals.account_profile_llr.to_f +
          signals.anti_bot_llr.to_f
      end

      # Graded by cross-channel temporal recurrence R (2/3/4/≥7 → increasing LLR).
      def self.temporal(signals, k)
        r = signals.temporal_recurrence
        return 0.0 unless r
        return k.llr_temporal_r7 if r >= 7
        return k.llr_temporal_r4 if r >= 4
        return k.llr_temporal_r3 if r >= 3
        return k.llr_temporal_r2 if r >= 2

        0.0
      end
      private_class_method :temporal

      # Linear illustrative scaling of the per-user scorer output (score=1.0 → full LLR); GATE-0 refines.
      def self.per_user(signals, k)
        s = signals.per_user_bot_score
        s ? s * k.llr_per_user_bot_score : 0.0
      end
      private_class_method :per_user
    end
  end
end
