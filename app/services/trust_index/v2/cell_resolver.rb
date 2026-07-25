# frozen_string_literal: true

module TrustIndex
  module V2
    # Resolves the L2 per-cell honest baseline ρ* for a stream's cell (category × V-bucket × chat-mode
    # × language) from calibration_cell_baselines (SRS FR-003 / R-007). Exact cell first, then the
    # "default" category, then up the parent_cell chain for a sparse/uncalibrated cell (hierarchical
    # shrinkage). Returns the resolved baseline or nil (caller decides cold-start / conservative default).
    class CellResolver
      # calibrated = whether the RESOLVED baseline is a real GATE-0 cell (true) vs an uncalibrated/
      # illustrative fallback (false). Threaded to L4/BandClassifier so the moat never PUBLICLY ACCUSES
      # (RED/YELLOW) off an uncalibrated per-cell ρ* — the deficit is only trustworthy on a calibrated cell.
      # TI v2.1 C_pop: rho_p1 = the P1 (extreme-low) tail of the cell's honest chat-share (the accusation
      # threshold — below 99% of honest peers, a tail cut not the P10 rho_lo where the honest bottom decile
      # legitimately lives); ccv_typical = the cell-median online (population_elevated? reference). Both nil
      # on an un-reseeded / DEFAULT cell → C_pop inert there.
      Baseline = Data.define(:rho_star, :rho_lo, :rho_hi, :calibrated, :rho_p1, :ccv_typical)

      def self.call(category:, v_bucket:, chat_mode:, language:)
        cell = CalibrationCellBaseline.for_cell(
          category: category, v_bucket: v_bucket, chat_mode: chat_mode, language: language
        ) || CalibrationCellBaseline.for_cell(
          category: "default", v_bucket: v_bucket, chat_mode: chat_mode, language: language
        )
        return nil unless cell

        r = cell.resolved
        Baseline.new(rho_star: r.rho_star, rho_lo: r.rho_lo, rho_hi: r.rho_hi, calibrated: !!r.calibrated,
                     # respond_to? tolerates a pre-migration record (col absent) → nil → C_pop inert.
                     rho_p1: (r.rho_p1 if r.respond_to?(:rho_p1)),
                     ccv_typical: (r.ccv_typical if r.respond_to?(:ccv_typical)))
      end
    end
  end
end
