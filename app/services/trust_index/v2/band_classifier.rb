# frozen_string_literal: true

module TrustIndex
  module V2
    # 6-row first-match band table (SRS FR-008 / Glossary §D). Pure function on the L3/L4 drivers —
    # NOT on an Authenticity threshold: accusatory rows can fire at high A (N_frac ≥ φ_red with a small
    # F̂ → A ≈ 90). Accusatory rows 1-2 require C_hard ∨ C_self corroboration; a soft engagement deficit
    # alone NEVER accuses → AMBER (row 6, ELSE catch-all sealing the cold-start dead-zone).
    #
    # drivers — responds to: n_frac, f_self_ratio (F_self/V), f_soft_lo_ratio (F_soft_lo/V), a_hat (F̂/V),
    #   q, i_event, c_hard, c_self, raid_window, cold_start_tier.
    # k — calibration thresholds: phi_yellow, phi_red, q_mid, q_hi.
    class BandClassifier
      Band = Data.define(:row, :color, :label_key, :sub)

      def self.call(drivers:, k:)
        new(drivers, k).call
      end

      def initialize(drivers, k)
        @d = drivers
        @k = k
      end

      def call
        return band(1, "red", "band.red_significant") if row1?
        return band(2, "yellow", "band.yellow_anomaly") if row2?
        return band(3, "green", "band.green_real") if row3?
        return band(4, "green", "band.green_no_anomaly") if row4?
        return band(5, "grey", "band.grey_insufficient") if row5?
        band(6, "amber", "band.amber_exceeds", @d.a_hat <= 0.50 ? "6a" : "6b") # ELSE — non-accusatory
      end

      private

      def corroborated?
        @d.c_hard || @d.c_self
      end

      def row1?
        @d.n_frac >= @k.phi_red ||
          (@d.i_event && @d.f_self_ratio >= 0.50 && !@d.raid_window) ||
          (@d.f_soft_lo_ratio >= 0.50 && corroborated?)
      end

      def row2?
        @d.n_frac >= @k.phi_yellow ||
          (@d.i_event && @d.f_self_ratio >= 0.20 && !@d.raid_window) ||
          (@d.f_soft_lo_ratio >= 0.20 && corroborated?)
      end

      def row3?
        @d.a_hat <= 0.10 && @d.q >= @k.q_hi && @d.n_frac < @k.phi_yellow &&
          !@d.i_event && @d.cold_start_tier == "full"
      end

      def row4?
        @d.a_hat <= 0.20 && @d.q >= @k.q_mid && @d.n_frac < @k.phi_yellow &&
          !@d.i_event && %w[full basic].include?(@d.cold_start_tier)
      end

      def row5?
        @d.cold_start_tier == "insufficient" && @d.a_hat <= 0.20 &&
          @d.n_frac < @k.phi_yellow && !@d.i_event
      end

      def band(row, color, label_key, sub = nil)
        Band.new(row: row, color: color, label_key: label_key, sub: sub)
      end
    end
  end
end
